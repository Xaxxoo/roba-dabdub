import { IsNumber, IsString, IsOptional, Min } from 'class-validator';
import { ApiProperty } from '@nestjs/swagger';

export class GenerateQRDto {
  @ApiProperty({ description: 'Amount in NGN' })
  @IsNumber()
  @Min(1)
  amount: number;

  @ApiProperty({ default: 'NGN' })
  @IsString()
  currency: string = 'NGN';

  @ApiProperty({ required: false })
  @IsOptional()
  @IsString()
  reference?: string;

  @ApiProperty({ required: false })
  @IsOptional()
  @IsString()
  description?: string;
}