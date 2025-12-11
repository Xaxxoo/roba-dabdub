import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { BullModule } from '@nestjs/bull';
import { PaymentController } from './payment.controller';
import { PaymentService } from './payment.service';
import { PaymentProcessor } from './payment.processor';
import { Transaction } from './entities/transaction.entity';
import { MerchantModule } from '../merchant/merchant.module';
import { BlockchainModule } from '../blockchain/blockchain.module';
import { SettlementModule } from '../settlement/settlement.module';

@Module({
  imports: [
    TypeOrmModule.forFeature([Transaction]),
    BullModule.registerQueue({
      name: 'payment-processing',
    }),
    MerchantModule,
    BlockchainModule,
    SettlementModule,
  ],
  controllers: [PaymentController],
  providers: [PaymentService, PaymentProcessor],
  exports: [PaymentService],
})
export class PaymentModule {}
