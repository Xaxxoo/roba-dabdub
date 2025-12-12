import { Processor, Process } from '@nestjs/bull';
import { Job } from 'bull';
import { Logger } from '@nestjs/common';
import { PaymentService } from './payment.service';
import { BlockchainService } from '../blockchain/blockchain.service';
import { SettlementService } from '../settlement/settlement.service';
import { TransactionStatus } from './entities/transaction.entity';

@Processor('payment-processing')
export class PaymentProcessor {
  private readonly logger = new Logger(PaymentProcessor.name);

  constructor(
    private paymentService: PaymentService,
    private blockchainService: BlockchainService,
    private settlementService: SettlementService,
  ) {}

  @Process('process-payment')
  async handlePayment(job: Job) {
    const { transactionId, userOperation, signature } = job.data;
    this.logger.log(`Processing payment for transaction: ${transactionId}`);

    try {
      const transaction = await this.paymentService.findById(transactionId);
      
      if (!transaction) {
        throw new Error('Transaction not found');
      }

      this.logger.log(`Step 1: Debiting crypto from user wallet`);
      const txHash = await this.blockchainService.debitUserAccount(
        transaction.user.walletAddress,
        transaction.amountCrypto,
        transaction.cryptoToken,
        userOperation,
        signature,
      );

      await this.paymentService.updateTransactionStatus(
        transactionId,
        TransactionStatus.CONFIRMED,
        txHash,
      );

      this.logger.log(`Crypto debited successfully. TxHash: ${txHash}`);

      await this.blockchainService.waitForConfirmation(txHash);
      this.logger.log(`Blockchain confirmation received`);

      await this.paymentService.updateTransactionStatus(
        transactionId,
        TransactionStatus.SETTLING,
      );

      this.logger.log(`Step 2: Initiating fiat settlement`);
      await this.settlementService.initiateSettlement(transaction);

      this.logger.log(`Payment processing completed for ${transactionId}`);
    } catch (error) {
      this.logger.error(`Payment processing failed: ${error.message}`, error.stack);
      
      await this.paymentService.updateTransactionStatus(
        transactionId,
        TransactionStatus.FAILED,
      );

      throw error;
    }
  }
}