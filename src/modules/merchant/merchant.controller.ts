import {
  Controller,
  Post,
  Get,
  Body,
  UseGuards,
  Request,
  HttpStatus,
  HttpException,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { MerchantService } from './merchant.service';
import { JwtAuthGuard } from '../auth/guards/jwt-auth.guard';
import { RolesGuard } from '../auth/guards/roles.guard';
import { Roles } from '../auth/decorators/roles.decorator';
import { UserRole } from '../auth/entities/user.entity';
import { CreateMerchantDto } from './dto/create-merchant.dto';
import { GenerateQRDto } from './dto/generate-qr.dto';

@ApiTags('Merchant')
@Controller('merchant')
@UseGuards(JwtAuthGuard, RolesGuard)
@ApiBearerAuth()
export class MerchantController {
  constructor(private merchantService: MerchantService) {}

  @Post('register')
  @Roles(UserRole.MERCHANT, UserRole.ADMIN)
  @ApiOperation({ summary: 'Register as merchant' })
  async register(@Request() req, @Body() dto: CreateMerchantDto) {
    return this.merchantService.createMerchant(req.user, dto);
  }

  @Get('profile')
  @Roles(UserRole.MERCHANT, UserRole.ADMIN)
  @ApiOperation({ summary: 'Get merchant profile' })
  async getProfile(@Request() req) {
    const merchant = await this.merchantService.findByUser(req.user.id);
    if (!merchant) {
      throw new HttpException('Merchant not found', HttpStatus.NOT_FOUND);
    }
    return merchant;
  }

  @Post('qr/generate')
  @Roles(UserRole.MERCHANT, UserRole.ADMIN)
  @ApiOperation({ summary: 'Generate payment QR code' })
  async generateQR(@Request() req, @Body() dto: GenerateQRDto) {
    const merchant = await this.merchantService.findByUser(req.user.id);
    if (!merchant) {
      throw new HttpException('Merchant not registered', HttpStatus.BAD_REQUEST);
    }
    return this.merchantService.generateQRCode(merchant, dto);
  }
}