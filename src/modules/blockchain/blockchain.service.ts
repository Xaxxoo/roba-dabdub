import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { ethers } from 'ethers';

const ERC20_ABI = [
  'function transfer(address to, uint256 amount) returns (bool)',
  'function balanceOf(address account) view returns (uint256)',
  'function decimals() view returns (uint8)',
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function totalSupply() view returns (uint256)',
];

@Injectable()
export class BlockchainService {
  private readonly logger = new Logger(BlockchainService.name);
  private provider: ethers.JsonRpcProvider;
  private wallet: ethers.Wallet;

  constructor(private configService: ConfigService) {
    const rpcUrl = this.configService.get('BLOCKCHAIN_RPC_URL');
    const privateKey = this.configService.get('PRIVATE_KEY');

    if (!rpcUrl) {
      throw new Error(
        'BLOCKCHAIN_RPC_URL is not configured in environment variables',
      );
    }

    if (!privateKey || privateKey.includes('your-wallet-private-key')) {
      throw new Error(
        'PRIVATE_KEY is not configured properly. Please set a valid private key in your .env file. ' +
          "You can generate one using: node -e \"console.log(require('crypto').randomBytes(32).toString('hex'))\"",
      );
    }

    // Ensure private key has 0x prefix
    const formattedPrivateKey = privateKey.startsWith('0x')
      ? privateKey
      : `0x${privateKey}`;

    this.provider = new ethers.JsonRpcProvider(rpcUrl);
    this.wallet = new ethers.Wallet(formattedPrivateKey, this.provider);

    this.logger.log(`Blockchain service initialized on ${rpcUrl}`);
    this.logger.log(`Wallet address: ${this.wallet.address}`);
  }

  async debitUserAccount(
    userAddress: string,
    amount: number,
    token: string,
    userOperation?: any,
    signature?: string,
  ): Promise<string> {
    try {
      this.logger.log(`Debiting ${amount} ${token} from ${userAddress}`);

      const tokenAddress = this.getTokenAddress(token);
      const tokenContract = new ethers.Contract(
        tokenAddress,
        ERC20_ABI,
        this.wallet,
      );
      const decimals = await tokenContract.decimals();
      const amountInWei = ethers.parseUnits(amount.toString(), decimals);

      let txHash: string;

      if (userOperation) {
        this.logger.log('Using Account Abstraction (ERC-4337)');
        txHash = await this.executeUserOperation(userOperation);
      } else if (signature) {
        this.logger.log('Using meta-transaction with signature');
        txHash = await this.executeMetaTransaction(
          userAddress,
          tokenAddress,
          amountInWei,
          signature,
        );
      } else {
        this.logger.log('Using direct transfer');
        const paymentContractAddress = this.configService.get(
          'PAYMENT_CONTRACT_ADDRESS',
        );

        if (!paymentContractAddress) {
          throw new Error('Payment contract not configured');
        }

        const paymentContract = new ethers.Contract(
          paymentContractAddress,
          [
            'function processPayment(address user, address token, uint256 amount) returns (bool)',
          ],
          this.wallet,
        );

        const tx = await paymentContract.processPayment(
          userAddress,
          tokenAddress,
          amountInWei,
        );
        await tx.wait();
        txHash = tx.hash;
      }

      this.logger.log(`Transaction successful: ${txHash}`);
      return txHash;
    } catch (error) {
      this.logger.error(`Blockchain debit failed: ${error.message}`);
      throw error;
    }
  }

  async getBalance(
    walletAddress: string,
    token: string = 'USDT',
  ): Promise<string> {
    try {
      const tokenAddress = this.getTokenAddress(token);
      const tokenContract = new ethers.Contract(
        tokenAddress,
        ERC20_ABI,
        this.provider,
      );

      const balance = await tokenContract.balanceOf(walletAddress);
      const decimals = await tokenContract.decimals();

      const formattedBalance = ethers.formatUnits(balance, decimals);

      this.logger.log(
        `Balance for ${walletAddress}: ${formattedBalance} ${token}`,
      );
      return formattedBalance;
    } catch (error) {
      this.logger.error(`Failed to get balance: ${error.message}`);
      throw error;
    }
  }

  async getTransactionReceipt(txHash: string): Promise<any> {
    try {
      const receipt = await this.provider.getTransactionReceipt(txHash);

      if (!receipt) {
        throw new Error('Transaction receipt not found');
      }

      // Get current block number to calculate confirmations
      const currentBlock = await this.provider.getBlockNumber();
      const confirmations = currentBlock - receipt.blockNumber;

      this.logger.log(`Transaction ${txHash} receipt retrieved`);

      return {
        ...receipt,
        confirmations,
      };
    } catch (error) {
      this.logger.error(`Failed to get transaction receipt: ${error.message}`);
      throw error;
    }
  }

  async isTransactionConfirmed(
    txHash: string,
    requiredConfirmations: number = 3,
  ): Promise<boolean> {
    try {
      const receipt = await this.provider.getTransactionReceipt(txHash);

      if (!receipt) {
        return false;
      }

      if (receipt.status === 0) {
        this.logger.warn(`Transaction ${txHash} failed on blockchain`);
        return false;
      }

      const currentBlock = await this.provider.getBlockNumber();
      const confirmations = currentBlock - receipt.blockNumber;

      const isConfirmed = confirmations >= requiredConfirmations;

      this.logger.log(
        `Transaction ${txHash} has ${confirmations} confirmations (required: ${requiredConfirmations})`,
      );

      return isConfirmed;
    } catch (error) {
      this.logger.error(
        `Failed to check transaction confirmation: ${error.message}`,
      );
      throw error;
    }
  }

  async getGasPrice(): Promise<bigint> {
    try {
      const feeData = await this.provider.getFeeData();
      const gasPrice = feeData.gasPrice || 0n;

      this.logger.log(
        `Current gas price: ${ethers.formatUnits(gasPrice, 'gwei')} gwei`,
      );

      return gasPrice;
    } catch (error) {
      this.logger.error(`Failed to get gas price: ${error.message}`);
      throw error;
    }
  }

  async getNetworkInfo(): Promise<any> {
    try {
      const network = await this.provider.getNetwork();
      const blockNumber = await this.provider.getBlockNumber();
      const gasPrice = await this.getGasPrice();

      const networkInfo = {
        chainId: network.chainId.toString(),
        name: network.name,
        currentBlock: blockNumber,
        gasPrice: gasPrice.toString(),
        gasPriceGwei: ethers.formatUnits(gasPrice, 'gwei'),
        rpcUrl: this.configService.get('BLOCKCHAIN_RPC_URL'),
      };

      this.logger.log(`Network info retrieved for chain ${network.chainId}`);

      return networkInfo;
    } catch (error) {
      this.logger.error(`Failed to get network info: ${error.message}`);
      throw error;
    }
  }

  async getTokenInfo(symbol: string): Promise<any> {
    try {
      const tokenAddress = this.getTokenAddress(symbol);
      const tokenContract = new ethers.Contract(
        tokenAddress,
        ERC20_ABI,
        this.provider,
      );

      const [name, tokenSymbol, decimals, totalSupply] = await Promise.all([
        tokenContract.name(),
        tokenContract.symbol(),
        tokenContract.decimals(),
        tokenContract.totalSupply(),
      ]);

      const tokenInfo = {
        address: tokenAddress,
        name,
        symbol: tokenSymbol,
        decimals: Number(decimals),
        totalSupply: ethers.formatUnits(totalSupply, decimals),
        totalSupplyRaw: totalSupply.toString(),
      };

      this.logger.log(`Token info retrieved for ${symbol}`);

      return tokenInfo;
    } catch (error) {
      this.logger.error(
        `Failed to get token info for ${symbol}: ${error.message}`,
      );
      throw error;
    }
  }

  private async executeUserOperation(userOperation: any): Promise<string> {
    const bundlerUrl = this.configService.get('BUNDLER_URL');

    if (!bundlerUrl) {
      throw new Error('Bundler URL not configured');
    }

    try {
      const response = await fetch(bundlerUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: 1,
          method: 'eth_sendUserOperation',
          params: [userOperation, this.configService.get('ENTRYPOINT_ADDRESS')],
        }),
      });

      const result = await response.json();

      if (result.error) {
        throw new Error(`Bundler error: ${result.error.message}`);
      }

      const userOpHash = result.result;
      this.logger.log(`User operation sent: ${userOpHash}`);

      const receipt = await this.waitForUserOperation(userOpHash);
      return receipt.transactionHash;
    } catch (error) {
      this.logger.error(`User operation failed: ${error.message}`);
      throw error;
    }
  }

  private async waitForUserOperation(userOpHash: string): Promise<any> {
    const bundlerUrl = this.configService.get('BUNDLER_URL');
    const maxAttempts = 30;
    let attempts = 0;

    while (attempts < maxAttempts) {
      try {
        const response = await fetch(bundlerUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: 1,
            method: 'eth_getUserOperationReceipt',
            params: [userOpHash],
          }),
        });

        const result = await response.json();

        if (result.result) {
          return result.result;
        }
      } catch (error) {
        this.logger.warn(`Waiting for user operation: attempt ${attempts + 1}`);
      }

      await new Promise((resolve) => setTimeout(resolve, 2000));
      attempts++;
    }

    throw new Error('User operation timed out');
  }

  private async executeMetaTransaction(
    userAddress: string,
    tokenAddress: string,
    amount: bigint,
    signature: string,
  ): Promise<string> {
    const paymentContractAddress = this.configService.get(
      'PAYMENT_CONTRACT_ADDRESS',
    );

    if (!paymentContractAddress) {
      throw new Error('Payment contract not configured');
    }

    const paymentContract = new ethers.Contract(
      paymentContractAddress,
      [
        'function executeMetaTransaction(address user, address token, uint256 amount, bytes signature) returns (bool)',
      ],
      this.wallet,
    );

    const tx = await paymentContract.executeMetaTransaction(
      userAddress,
      tokenAddress,
      amount,
      signature,
    );
    await tx.wait();
    return tx.hash;
  }

  async waitForConfirmation(txHash: string, confirmations = 3): Promise<void> {
    try {
      const receipt = await this.provider.waitForTransaction(
        txHash,
        confirmations,
      );

      if (!receipt) {
        throw new Error('Transaction receipt not found');
      }

      if (receipt.status === 0) {
        throw new Error('Transaction failed on blockchain');
      }

      this.logger.log(
        `Transaction ${txHash} confirmed with ${confirmations} blocks`,
      );
    } catch (error) {
      this.logger.error(`Confirmation wait failed: ${error.message}`);
      throw error;
    }
  }

  private getTokenAddress(token: string): string {
    const tokens = {
      USDT:
        this.configService.get('USDT_CONTRACT_ADDRESS') ||
        '0xc2132D05D31c914a87C6611C10748AEb04B58e8F',
      USDC:
        this.configService.get('USDC_CONTRACT_ADDRESS') ||
        '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174',
    };

    const tokenAddress = tokens[token.toUpperCase()];

    if (!tokenAddress) {
      throw new Error(
        `Token ${token} not supported. Available tokens: ${Object.keys(
          tokens,
        ).join(', ')}`,
      );
    }

    return tokenAddress;
  }
}
// import { Injectable, Logger } from '@nestjs/common';
// import { ConfigService } from '@nestjs/config';
// import { ethers } from 'ethers';

// const ERC20_ABI = [
//   'function transfer(address to, uint256 amount) returns (bool)',
//   'function balanceOf(address account) view returns (uint256)',
//   'function decimals() view returns (uint8)',
//   'function name() view returns (string)',
//   'function symbol() view returns (string)',
//   'function totalSupply() view returns (uint256)',
// ];

// @Injectable()
// export class BlockchainService {
//   private readonly logger = new Logger(BlockchainService.name);
//   private provider: ethers.JsonRpcProvider;
//   private wallet: ethers.Wallet;

//   constructor(private configService: ConfigService) {
//     const rpcUrl = this.configService.get('BLOCKCHAIN_RPC_URL');
//     const privateKey = this.configService.get('PRIVATE_KEY');

//     this.provider = new ethers.JsonRpcProvider(rpcUrl);
//     this.wallet = new ethers.Wallet(privateKey, this.provider);

//     this.logger.log(`Blockchain service initialized on ${rpcUrl}`);
//   }

//   async debitUserAccount(
//     userAddress: string,
//     amount: number,
//     token: string,
//     userOperation?: any,
//     signature?: string,
//   ): Promise<string> {
//     try {
//       this.logger.log(`Debiting ${amount} ${token} from ${userAddress}`);

//       const tokenAddress = this.getTokenAddress(token);
//       const tokenContract = new ethers.Contract(
//         tokenAddress,
//         ERC20_ABI,
//         this.wallet,
//       );
//       const decimals = await tokenContract.decimals();
//       const amountInWei = ethers.parseUnits(amount.toString(), decimals);

//       let txHash: string;

//       if (userOperation) {
//         this.logger.log('Using Account Abstraction (ERC-4337)');
//         txHash = await this.executeUserOperation(userOperation);
//       } else if (signature) {
//         this.logger.log('Using meta-transaction with signature');
//         txHash = await this.executeMetaTransaction(
//           userAddress,
//           tokenAddress,
//           amountInWei,
//           signature,
//         );
//       } else {
//         this.logger.log('Using direct transfer');
//         const paymentContractAddress = this.configService.get(
//           'PAYMENT_CONTRACT_ADDRESS',
//         );

//         if (!paymentContractAddress) {
//           throw new Error('Payment contract not configured');
//         }

//         const paymentContract = new ethers.Contract(
//           paymentContractAddress,
//           [
//             'function processPayment(address user, address token, uint256 amount) returns (bool)',
//           ],
//           this.wallet,
//         );

//         const tx = await paymentContract.processPayment(
//           userAddress,
//           tokenAddress,
//           amountInWei,
//         );
//         await tx.wait();
//         txHash = tx.hash;
//       }

//       this.logger.log(`Transaction successful: ${txHash}`);
//       return txHash;
//     } catch (error) {
//       this.logger.error(`Blockchain debit failed: ${error.message}`);
//       throw error;
//     }
//   }

//   async getBalance(
//     walletAddress: string,
//     token: string = 'USDT',
//   ): Promise<string> {
//     try {
//       const tokenAddress = this.getTokenAddress(token);
//       const tokenContract = new ethers.Contract(
//         tokenAddress,
//         ERC20_ABI,
//         this.provider,
//       );

//       const balance = await tokenContract.balanceOf(walletAddress);
//       const decimals = await tokenContract.decimals();

//       const formattedBalance = ethers.formatUnits(balance, decimals);

//       this.logger.log(
//         `Balance for ${walletAddress}: ${formattedBalance} ${token}`,
//       );
//       return formattedBalance;
//     } catch (error) {
//       this.logger.error(`Failed to get balance: ${error.message}`);
//       throw error;
//     }
//   }

//   async getTransactionReceipt(txHash: string): Promise<any> {
//     try {
//       const receipt = await this.provider.getTransactionReceipt(txHash);

//       if (!receipt) {
//         throw new Error('Transaction receipt not found');
//       }

//       // Get current block number to calculate confirmations
//       const currentBlock = await this.provider.getBlockNumber();
//       const confirmations = currentBlock - receipt.blockNumber;

//       this.logger.log(`Transaction ${txHash} receipt retrieved`);

//       return {
//         ...receipt,
//         confirmations,
//       };
//     } catch (error) {
//       this.logger.error(`Failed to get transaction receipt: ${error.message}`);
//       throw error;
//     }
//   }

//   async isTransactionConfirmed(
//     txHash: string,
//     requiredConfirmations: number = 3,
//   ): Promise<boolean> {
//     try {
//       const receipt = await this.provider.getTransactionReceipt(txHash);

//       if (!receipt) {
//         return false;
//       }

//       if (receipt.status === 0) {
//         this.logger.warn(`Transaction ${txHash} failed on blockchain`);
//         return false;
//       }

//       const currentBlock = await this.provider.getBlockNumber();
//       const confirmations = currentBlock - receipt.blockNumber;

//       const isConfirmed = confirmations >= requiredConfirmations;

//       this.logger.log(
//         `Transaction ${txHash} has ${confirmations} confirmations (required: ${requiredConfirmations})`,
//       );

//       return isConfirmed;
//     } catch (error) {
//       this.logger.error(
//         `Failed to check transaction confirmation: ${error.message}`,
//       );
//       throw error;
//     }
//   }

//   async getGasPrice(): Promise<bigint> {
//     try {
//       const feeData = await this.provider.getFeeData();
//       const gasPrice = feeData.gasPrice || 0n;

//       this.logger.log(
//         `Current gas price: ${ethers.formatUnits(gasPrice, 'gwei')} gwei`,
//       );

//       return gasPrice;
//     } catch (error) {
//       this.logger.error(`Failed to get gas price: ${error.message}`);
//       throw error;
//     }
//   }

//   async getNetworkInfo(): Promise<any> {
//     try {
//       const network = await this.provider.getNetwork();
//       const blockNumber = await this.provider.getBlockNumber();
//       const gasPrice = await this.getGasPrice();

//       const networkInfo = {
//         chainId: network.chainId.toString(),
//         name: network.name,
//         currentBlock: blockNumber,
//         gasPrice: gasPrice.toString(),
//         gasPriceGwei: ethers.formatUnits(gasPrice, 'gwei'),
//         rpcUrl: this.configService.get('BLOCKCHAIN_RPC_URL'),
//       };

//       this.logger.log(`Network info retrieved for chain ${network.chainId}`);

//       return networkInfo;
//     } catch (error) {
//       this.logger.error(`Failed to get network info: ${error.message}`);
//       throw error;
//     }
//   }

//   async getTokenInfo(symbol: string): Promise<any> {
//     try {
//       const tokenAddress = this.getTokenAddress(symbol);
//       const tokenContract = new ethers.Contract(
//         tokenAddress,
//         ERC20_ABI,
//         this.provider,
//       );

//       const [name, tokenSymbol, decimals, totalSupply] = await Promise.all([
//         tokenContract.name(),
//         tokenContract.symbol(),
//         tokenContract.decimals(),
//         tokenContract.totalSupply(),
//       ]);

//       const tokenInfo = {
//         address: tokenAddress,
//         name,
//         symbol: tokenSymbol,
//         decimals: Number(decimals),
//         totalSupply: ethers.formatUnits(totalSupply, decimals),
//         totalSupplyRaw: totalSupply.toString(),
//       };

//       this.logger.log(`Token info retrieved for ${symbol}`);

//       return tokenInfo;
//     } catch (error) {
//       this.logger.error(
//         `Failed to get token info for ${symbol}: ${error.message}`,
//       );
//       throw error;
//     }
//   }

//   private async executeUserOperation(userOperation: any): Promise<string> {
//     const bundlerUrl = this.configService.get('BUNDLER_URL');

//     if (!bundlerUrl) {
//       throw new Error('Bundler URL not configured');
//     }

//     try {
//       const response = await fetch(bundlerUrl, {
//         method: 'POST',
//         headers: { 'Content-Type': 'application/json' },
//         body: JSON.stringify({
//           jsonrpc: '2.0',
//           id: 1,
//           method: 'eth_sendUserOperation',
//           params: [userOperation, this.configService.get('ENTRYPOINT_ADDRESS')],
//         }),
//       });

//       const result = await response.json();

//       if (result.error) {
//         throw new Error(`Bundler error: ${result.error.message}`);
//       }

//       const userOpHash = result.result;
//       this.logger.log(`User operation sent: ${userOpHash}`);

//       const receipt = await this.waitForUserOperation(userOpHash);
//       return receipt.transactionHash;
//     } catch (error) {
//       this.logger.error(`User operation failed: ${error.message}`);
//       throw error;
//     }
//   }

//   private async waitForUserOperation(userOpHash: string): Promise<any> {
//     const bundlerUrl = this.configService.get('BUNDLER_URL');
//     const maxAttempts = 30;
//     let attempts = 0;

//     while (attempts < maxAttempts) {
//       try {
//         const response = await fetch(bundlerUrl, {
//           method: 'POST',
//           headers: { 'Content-Type': 'application/json' },
//           body: JSON.stringify({
//             jsonrpc: '2.0',
//             id: 1,
//             method: 'eth_getUserOperationReceipt',
//             params: [userOpHash],
//           }),
//         });

//         const result = await response.json();

//         if (result.result) {
//           return result.result;
//         }
//       } catch (error) {
//         this.logger.warn(`Waiting for user operation: attempt ${attempts + 1}`);
//       }

//       await new Promise((resolve) => setTimeout(resolve, 2000));
//       attempts++;
//     }

//     throw new Error('User operation timed out');
//   }

//   private async executeMetaTransaction(
//     userAddress: string,
//     tokenAddress: string,
//     amount: bigint,
//     signature: string,
//   ): Promise<string> {
//     const paymentContractAddress = this.configService.get(
//       'PAYMENT_CONTRACT_ADDRESS',
//     );

//     if (!paymentContractAddress) {
//       throw new Error('Payment contract not configured');
//     }

//     const paymentContract = new ethers.Contract(
//       paymentContractAddress,
//       [
//         'function executeMetaTransaction(address user, address token, uint256 amount, bytes signature) returns (bool)',
//       ],
//       this.wallet,
//     );

//     const tx = await paymentContract.executeMetaTransaction(
//       userAddress,
//       tokenAddress,
//       amount,
//       signature,
//     );
//     await tx.wait();
//     return tx.hash;
//   }

//   async waitForConfirmation(txHash: string, confirmations = 3): Promise<void> {
//     try {
//       const receipt = await this.provider.waitForTransaction(
//         txHash,
//         confirmations,
//       );

//       if (!receipt) {
//         throw new Error('Transaction receipt not found');
//       }

//       if (receipt.status === 0) {
//         throw new Error('Transaction failed on blockchain');
//       }

//       this.logger.log(
//         `Transaction ${txHash} confirmed with ${confirmations} blocks`,
//       );
//     } catch (error) {
//       this.logger.error(`Confirmation wait failed: ${error.message}`);
//       throw error;
//     }
//   }

//   private getTokenAddress(token: string): string {
//     const tokens = {
//       USDT:
//         this.configService.get('USDT_CONTRACT_ADDRESS') ||
//         '0xc2132D05D31c914a87C6611C10748AEb04B58e8F',
//       USDC:
//         this.configService.get('USDC_CONTRACT_ADDRESS') ||
//         '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174',
//     };

//     const tokenAddress = tokens[token.toUpperCase()];

//     if (!tokenAddress) {
//       throw new Error(
//         `Token ${token} not supported. Available tokens: ${Object.keys(
//           tokens,
//         ).join(', ')}`,
//       );
//     }

//     return tokenAddress;
//   }
// }
