import { Module, forwardRef } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { BullModule } from '@nestjs/bull';
import { SettlementController } from './settlement.controller';
import { SettlementService } from './settlement.service';
import { SettlementProcessor } from './settlement.processor';
import { Settlement } from './entities/settlement.entity';
import { MerchantModule } from '../merchant/merchant.module';
import { PaymentModule } from '../payment/payment.module';

@Module({
  imports: [
    TypeOrmModule.forFeature([Settlement]),
    BullModule.registerQueue({
      name: 'fiat-settlement',
    }),
    MerchantModule,
    forwardRef(() => PaymentModule),
  ],
  controllers: [SettlementController],
  providers: [SettlementService, SettlementProcessor],
  exports: [SettlementService],
})
export class SettlementModule {}