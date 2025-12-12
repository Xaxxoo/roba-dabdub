import { Controller, Get, Query, Param, UseGuards, Request } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth, ApiQuery } from '@nestjs/swagger';
import { BlockchainService } from './blockchain.service';
import { JwtAuthGuard } from '../auth/guards/jwt-auth.guard';

@ApiTags('Blockchain')
@Controller('blockchain')
@UseGuards(JwtAuthGuard)
@ApiBearerAuth()
export class BlockchainController {
  constructor(private blockchainService: BlockchainService) {}

  @Get('balance')
  @ApiOperation({ summary: 'Get wallet token balance' })
  @ApiQuery({ name: 'address', required: false, description: 'Wallet address (defaults to user wallet)' })
  @ApiQuery({ name: 'token', required: false, description: 'Token symbol (USDT, USDC)', example: 'USDT' })
  async getBalance(
    @Request() req,
    @Query('address') address?: string,
    @Query('token') token: string = 'USDT',
  ) {
    const walletAddress = address || req.user.walletAddress;
    
    if (!walletAddress) {
      return {
        error: 'No wallet address provided or linked to account',
      };
    }

    const balance = await this.blockchainService.getBalance(walletAddress, token);
    
    return {
      address: walletAddress,
      token,
      balance,
      formatted: `${balance} ${token}`,
    };
  }

  @Get('transaction/:txHash')
  @ApiOperation({ summary: 'Get transaction details from blockchain' })
  async getTransaction(@Param('txHash') txHash: string) {
    const receipt = await this.blockchainService.getTransactionReceipt(txHash);
    
    return {
      txHash,
      status: receipt.status === 1 ? 'success' : 'failed',
      blockNumber: receipt.blockNumber,
      confirmations: receipt.confirmations,
      gasUsed: receipt.gasUsed.toString(),
      from: receipt.from,
      to: receipt.to,
    };
  }

  @Get('transaction/:txHash/status')
  @ApiOperation({ summary: 'Check if transaction is confirmed' })
  async getTransactionStatus(@Param('txHash') txHash: string) {
    const isConfirmed = await this.blockchainService.isTransactionConfirmed(txHash, 3);
    
    return {
      txHash,
      confirmed: isConfirmed,
      requiredConfirmations: 3,
    };
  }

  @Get('gas-price')
  @ApiOperation({ summary: 'Get current gas price' })
  async getGasPrice() {
    const gasPrice = await this.blockchainService.getGasPrice();
    
    return {
      gasPrice: gasPrice.toString(),
      gasPriceGwei: (Number(gasPrice) / 1e9).toFixed(2),
    };
  }

  @Get('network-info')
  @ApiOperation({ summary: 'Get blockchain network information' })
  async getNetworkInfo() {
    const info = await this.blockchainService.getNetworkInfo();
    
    return info;
  }

  @Get('token/:symbol/info')
  @ApiOperation({ summary: 'Get token contract information' })
  async getTokenInfo(@Param('symbol') symbol: string) {
    const info = await this.blockchainService.getTokenInfo(symbol);
    
    return info;
  }
}