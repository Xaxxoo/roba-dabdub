import { IsString } from 'class-validator';
import { ApiProperty } from '@nestjs/swagger';

export class LoginDto {
  @ApiProperty()
  @IsString()
  emailOrUsername: string;

  @ApiProperty()
  @IsString()
  password: string;
}