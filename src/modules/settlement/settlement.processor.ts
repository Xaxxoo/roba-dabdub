import { Processor, Process } from '@nestjs/bull';
import { Job } from 'bull';
import { Logger } from '@nestjs/common';
import { SettlementService } from './settlement.service';
import { PaymentService } from '../payment/payment.service';
import { TransactionStatus } from '../payment/entities/transaction.entity';

@Processor('fiat-settlement')
export class SettlementProcessor {
  private readonly logger = new Logger(SettlementProcessor.name);

  constructor(
    private settlementService: SettlementService,
    private paymentService: PaymentService,
  ) {}

  @Process('process-settlement')
  async handleSettlement(job: Job) {
    const { settlementId } = job.data;
    this.logger.log(`Processing settlement: ${settlementId}`);

    try {
      const settlement = await this.settlementService.processSettlement(settlementId);
      
      await this.paymentService.updateTransactionStatus(
        settlement.transaction.id,
        TransactionStatus.SETTLED,
      );

      this.logger.log(`Settlement ${settlementId} completed successfully`);
    } catch (error) {
      this.logger.error(`Settlement processing failed: ${error.message}`, error.stack);
      throw error;
    }
  }
}