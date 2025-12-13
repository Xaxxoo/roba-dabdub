import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { InjectQueue } from '@nestjs/bull';
import bull from 'bull';
import { ConfigService } from '@nestjs/config';
import { Settlement, SettlementStatus } from './entities/settlement.entity';
import { Transaction } from '../payment/entities/transaction.entity';
import axios from 'axios';

@Injectable()
export class SettlementService {
  private readonly logger = new Logger(SettlementService.name);

  constructor(
    @InjectRepository(Settlement)
    private settlementRepository: Repository<Settlement>,
    private configService: ConfigService,
    @InjectQueue('fiat-settlement')
    private settlementQueue: bull.Queue,
  ) {}

  async initiateSettlement(transaction: Transaction) {
    this.logger.log(`Initiating settlement for transaction ${transaction.id}`);

    const settlement = this.settlementRepository.create({
      transaction,
      settlementReference: this.generateSettlementReference(),
      amount: transaction.amountFiat,
      currency: transaction.fiatCurrency,
      recipientDetails: transaction.merchant.bankDetails,
      status: SettlementStatus.PENDING,
    });

    const saved = await this.settlementRepository.save(settlement);

    await this.settlementQueue.add('process-settlement', {
      settlementId: saved.id,
    });

    return saved;
  }

  async processSettlement(settlementId: string) {
    const settlement = await this.settlementRepository.findOne({
      where: { id: settlementId },
      relations: ['transaction', 'transaction.merchant'],
    });

    if (!settlement) {
      throw new Error('Settlement not found');
    }

    try {
      settlement.status = SettlementStatus.PROCESSING;
      await this.settlementRepository.save(settlement);

      const response = await this.initiatePaystackTransfer(settlement);

      settlement.paymentGatewayReference = response.reference;
      settlement.gatewayResponse = response;
      settlement.status = SettlementStatus.COMPLETED;
      settlement.completedAt = new Date();

      await this.settlementRepository.save(settlement);

      this.logger.log(`Settlement ${settlementId} completed successfully`);

      return settlement;
    } catch (error) {
      this.logger.error(`Settlement failed: ${error.message}`);

      settlement.status = SettlementStatus.FAILED;
      settlement.failureReason = error.message;
      settlement.retryCount += 1;

      await this.settlementRepository.save(settlement);

      if (settlement.retryCount < 3) {
        await this.settlementQueue.add(
          'process-settlement',
          { settlementId },
          { delay: 60000 * settlement.retryCount },
        );
      }

      throw error;
    }
  }

  private async initiatePaystackTransfer(settlement: Settlement) {
    const paystackSecretKey = this.configService.get('PAYSTACK_SECRET_KEY');

    const recipientResponse = await axios.post(
      'https://api.paystack.co/transferrecipient',
      {
        type: 'nuban',
        name: settlement.recipientDetails.accountName,
        account_number: settlement.recipientDetails.accountNumber,
        bank_code: settlement.recipientDetails.bankCode,
        currency: settlement.currency,
      },
      {
        headers: {
          Authorization: `Bearer ${paystackSecretKey}`,
          'Content-Type': 'application/json',
        },
      },
    );

    const recipientCode = recipientResponse.data.data.recipient_code;

    const transferResponse = await axios.post(
      'https://api.paystack.co/transfer',
      {
        source: 'balance',
        amount: settlement.amount * 100,
        recipient: recipientCode,
        reason: `Settlement for ${settlement.settlementReference}`,
        reference: settlement.settlementReference,
      },
      {
        headers: {
          Authorization: `Bearer ${paystackSecretKey}`,
          'Content-Type': 'application/json',
        },
      },
    );

    return {
      reference: transferResponse.data.data.reference,
      recipientCode,
      ...transferResponse.data.data,
    };
  }

  async getMerchantSettlements(merchantId: string) {
    return this.settlementRepository.find({
      where: {
        transaction: { merchant: { id: merchantId } },
      },
      relations: ['transaction'],
      order: { createdAt: 'DESC' },
    });
  }

  async handleWebhook(payload: any) {
    this.logger.log('Received settlement webhook', payload);

    if (
      payload.event === 'transfer.success' ||
      payload.event === 'transfer.failed'
    ) {
      const reference = payload.data.reference;

      const settlement = await this.settlementRepository.findOne({
        where: { settlementReference: reference },
      });

      if (settlement) {
        if (payload.event === 'transfer.success') {
          settlement.status = SettlementStatus.COMPLETED;
          settlement.completedAt = new Date();
        } else {
          settlement.status = SettlementStatus.FAILED;
          settlement.failureReason = payload.data.reason;
        }

        await this.settlementRepository.save(settlement);
        this.logger.log(`Settlement ${reference} updated via webhook`);
      }
    }
  }

  private generateSettlementReference(): string {
    return `SETTLE${Date.now()}${Math.random()
      .toString(36)
      .substr(2, 9)
      .toUpperCase()}`;
  }
}
