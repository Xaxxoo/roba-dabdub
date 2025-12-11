import {
  Controller,
  Post,
  Get,
  Body,
  Param,
  Query,
  UseGuards,
  Request,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { PaymentService } from './payment.service';
import { JwtAuthGuard } from '../auth/guards/jwt-auth.guard';
import { RolesGuard } from '../auth/guards/roles.guard';
import { Roles } from '../auth/decorators/roles.decorator';
import { UserRole } from '../auth/entities/user.entity';
import { InitiatePaymentDto } from './dto/initiate-payment.dto';
import { ConfirmPaymentDto } from './dto/confirm-payment.dto';

@ApiTags('Payment')
@Controller('payment')
@UseGuards(JwtAuthGuard, RolesGuard)
@ApiBearerAuth()
export class PaymentController {
  constructor(private paymentService: PaymentService) {}

  @Post('initiate')
  @Roles(UserRole.CONSUMER, UserRole.ADMIN)
  @ApiOperation({ summary: 'Initiate payment (scan QR or username)' })
  async initiatePayment(@Request() req, @Body() dto: InitiatePaymentDto) {
    return this.paymentService.initiatePayment(req.user, dto);
  }

  @Post('confirm')
  @Roles(UserRole.CONSUMER, UserRole.ADMIN)
  @ApiOperation({ summary: 'Confirm and execute payment' })
  async confirmPayment(@Request() req, @Body() dto: ConfirmPaymentDto) {
    return this.paymentService.confirmPayment(req.user, dto);
  }

  @Get('status/:transactionId')
  @Roles(UserRole.CONSUMER, UserRole.MERCHANT, UserRole.ADMIN)
  @ApiOperation({ summary: 'Get transaction status' })
  async getStatus(@Request() req, @Param('transactionId') transactionId: string) {
    return this.paymentService.getTransactionStatus(transactionId, req.user.id);
  }

  @Get('history')
  @Roles(UserRole.CONSUMER, UserRole.ADMIN)
  @ApiOperation({ summary: 'Get user transaction history' })
  async getHistory(@Request() req, @Query('limit') limit?: number) {
    return this.paymentService.getUserTransactions(req.user.id, limit);
  }
}
