import {
  Controller,
  Get,
  Post,
  Body,
  UseGuards,
  Request,
  HttpCode,
  HttpStatus,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { SettlementService } from './settlement.service';
import { JwtAuthGuard } from '../auth/guards/jwt-auth.guard';
import { RolesGuard } from '../auth/guards/roles.guard';
import { Roles } from '../auth/decorators/roles.decorator';
import { UserRole } from '../auth/entities/user.entity';
import { MerchantService } from '../merchant/merchant.service';

@ApiTags('Settlement')
@Controller('settlement')
export class SettlementController {
  constructor(
    private settlementService: SettlementService,
    private merchantService: MerchantService,
  ) {}

  @Get('merchant/history')
  @UseGuards(JwtAuthGuard, RolesGuard)
  @Roles(UserRole.MERCHANT, UserRole.ADMIN)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Get merchant settlement history' })
  async getMerchantSettlements(@Request() req) {
    const merchant = await this.merchantService.findByUser(req.user.id);
    return this.settlementService.getMerchantSettlements(merchant.id);
  }

  @Post('webhook')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Webhook for payment gateway callbacks' })
  async handleWebhook(@Body() payload: any) {
    await this.settlementService.handleWebhook(payload);
    return { status: 'success' };
  }
}