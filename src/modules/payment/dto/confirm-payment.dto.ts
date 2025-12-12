import { IsString, IsOptional, IsObject } from 'class-validator';
import { ApiProperty } from '@nestjs/swagger';

export class ConfirmPaymentDto {
  @ApiProperty({ description: 'Transaction ID from initiate payment' })
  @IsString()
  transactionId: string;

  @ApiProperty({ description: 'User signature for account abstraction', required: false })
  @IsOptional()
  @IsString()
  signature?: string;

  @ApiProperty({ description: 'User operation data for AA', required: false })
  @IsOptional()
  @IsObject()
  userOperation?: {
    sender: string;
    nonce: string;
    initCode: string;
    callData: string;
    callGasLimit: string;
    verificationGasLimit: string;
    preVerificationGas: string;
    maxFeePerGas: string;
    maxPriorityFeePerGas: string;
    paymasterAndData: string;
    signature: string;
  };

  @ApiProperty({ description: 'Additional metadata', required: false })
  @IsOptional()
  @IsObject()
  metadata?: Record<string, any>;
}