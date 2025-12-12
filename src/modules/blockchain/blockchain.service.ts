import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { ethers } from 'ethers';

const ERC20_ABI = [
  'function transfer(address to, uint256 amount) returns (bool)',
  'function balanceOf(address account) view returns (uint256)',
  'function decimals() view returns (uint8)',
];

@Injectable()
export class BlockchainService {
  private readonly logger = new Logger(BlockchainService.name);
  private provider: ethers.JsonRpcProvider;
  private wallet: ethers.Wallet;

  constructor(private configService: ConfigService) {
    const rpcUrl = this.configService.get('BLOCKCHAIN_RPC_URL');
    const privateKey = this.configService.get('PRIVATE_KEY');

    this.provider = new ethers.JsonRpcProvider(rpcUrl);
    this.wallet = new ethers.Wallet(privateKey, this.provider);

    this.logger.log(`Blockchain service initialized on ${rpcUrl}`);
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
      const tokenContract = new ethers.Contract(tokenAddress, ERC20_ABI, this.wallet);
      const decimals = await tokenContract.decimals();
      const amountInWei = ethers.parseUnits(amount.toString(), decimals);

      let txHash: string;

      if (userOperation) {
        this.logger.log('Using Account Abstraction (ERC-4337)');
        txHash = await this.executeUserOperation(userOperation);
      } else if (signature) {
        this.logger.log('Using meta-transaction with signature');
        txHash = await this.executeMetaTransaction(userAddress, tokenAddress, amountInWei, signature);
      } else {
        this.logger.log('Using direct transfer');
        const paymentContractAddress = this.configService.get('PAYMENT_CONTRACT_ADDRESS');
        
        if (!paymentContractAddress) {
          throw new Error('Payment contract not configured');
        }

        const paymentContract = new ethers.Contract(
          paymentContractAddress,
          ['function processPayment(address user, address token, uint256 amount) returns (bool)'],
          this.wallet,
        );

        const tx = await paymentContract.processPayment(userAddress, tokenAddress, amountInWei);
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

      await new Promise(resolve => setTimeout(resolve, 2000));
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
    const paymentContractAddress = this.configService.get('PAYMENT_CONTRACT_ADDRESS');
    
    if (!paymentContractAddress) {
      throw new Error('Payment contract not configured');
    }

    const paymentContract = new ethers.Contract(
      paymentContractAddress,
      ['function executeMetaTransaction(address user, address token, uint256 amount, bytes signature) returns (bool)'],
      this.wallet,
    );

    const tx = await paymentContract.executeMetaTransaction(userAddress, tokenAddress, amount, signature);
    await tx.wait();
    return tx.hash;
  }

  async waitForConfirmation(txHash: string, confirmations = 3): Promise<void> {
    try {
      const receipt = await this.provider.waitForTransaction(txHash, confirmations);
      
      if (receipt.status === 0) {
        throw new Error('Transaction failed on blockchain');
      }

      this.logger.log(`Transaction ${txHash} confirmed with ${confirmations} blocks`);
    } catch (error) {
      this.logger.error(`Confirmation wait failed: ${error.message}`);
      throw error;
    }
  }

  private getTokenAddress(token: string): string {
    const tokens = {
      USDT: '0xc2132D05D31c914a87C6611C10748AEb04B58e8F',
      USDC: '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174',
    };
    return tokens[token] || tokens.USDT;
  }
}