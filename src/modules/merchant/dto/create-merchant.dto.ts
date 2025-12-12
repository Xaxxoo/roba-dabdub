import { IsString, IsObject, ValidateNested } from 'class-validator';
import { Type } from 'class-transformer';
import { ApiProperty } from '@nestjs/swagger';

class BankDetailsDto {
  @ApiProperty()
  @IsString()
  accountNumber: string;

  @ApiProperty()
  @IsString()
  accountName: string;

  @ApiProperty()
  @IsString()
  bankCode: string;

  @ApiProperty()
  @IsString()
  bankName: string;
}

export class CreateMerchantDto {
  @ApiProperty()
  @IsString()
  businessName: string;

  @ApiProperty()
  @IsObject()
  @ValidateNested()
  @Type(() => BankDetailsDto)
  bankDetails: BankDetailsDto;
}