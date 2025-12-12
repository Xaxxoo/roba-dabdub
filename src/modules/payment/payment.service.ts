import { Injectable, NotFoundException, BadRequestException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { InjectQueue } from '@nestjs/bull';
import { Queue } from 'bull';
import { ConfigService } from '@nestjs/config';
import { Transaction, TransactionStatus, TransactionType } from './entities/transaction.entity';
import { User } from '../auth/entities/user.entity';
import { MerchantService } from '../merchant/merchant.service';
import { InitiatePaymentDto } from './dto/initiate-payment.dto';
import { ConfirmPaymentDto } from './dto/confirm-payment.dto';

@Injectable()
export class PaymentService {
  constructor(
    @InjectRepository(Transaction)
    private transactionRepository: Repository<Transaction>,
    private merchantService: MerchantService,
    private configService: ConfigService,
    @InjectQueue('payment-processing')
    private paymentQueue: Queue,
  ) {}

  async initiatePayment(user: User, dto: InitiatePaymentDto) {
    const merchant = await this.merchantService.findByMerchantCode(dto.merchantCode);
    if (!merchant) {
      throw new NotFoundException('Merchant not found');
    }

    const existingTx = await this.transactionRepository.findOne({
      where: { reference: dto.reference },
    });
    if (existingTx) {
      throw new BadRequestException('Reference already used');
    }

    const conversionRate = this.configService.get<number>('USD_TO_NGN_RATE', 1500);
    const spread = this.configService.get<number>('CONVERSION_SPREAD', 0.02);
    const effectiveRate = conversionRate * (1 + spread);
    const amountCrypto = dto.amount / effectiveRate;

    const transaction = this.transactionRepository.create({
      reference: dto.reference,
      user,
      merchant,
      type: dto.type,
      amountCrypto,
      cryptoToken: 'USDT',
      amountFiat: dto.amount,
      fiatCurrency: dto.currency,
      conversionRate: effectiveRate,
      status: TransactionStatus.PENDING,
      expiresAt: new Date(Date.now() + 15 * 60 * 1000),
      metadata: {
        description: dto.description,
      },
    });

    const saved = await this.transactionRepository.save(transaction);

    return {
      transactionId: saved.id,
      reference: saved.reference,
      amountCrypto: saved.amountCrypto,
      amountFiat: saved.amountFiat,
      conversionRate: saved.conversionRate,
      expiresAt: saved.expiresAt,
      merchant: {
        businessName: merchant.businessName,
        merchantCode: merchant.merchantCode,
      },
    };
  }

  async confirmPayment(user: User, dto: ConfirmPaymentDto) {
    const transaction = await this.transactionRepository.findOne({
      where: { id: dto.transactionId, user: { id: user.id } },
      relations: ['merchant', 'user'],
    });

    if (!transaction) {
      throw new NotFoundException('Transaction not found');
    }

    if (transaction.status !== TransactionStatus.PENDING) {
      throw new BadRequestException('Transaction already processed');
    }

    if (new Date() > transaction.expiresAt) {
      transaction.status = TransactionStatus.EXPIRED;
      await this.transactionRepository.save(transaction);
      throw new BadRequestException('Transaction expired');
    }

    transaction.status = TransactionStatus.PROCESSING;
    
    if (dto.userOperation || dto.signature) {
      transaction.metadata = {
        ...transaction.metadata,
        userOperation: dto.userOperation,
        signature: dto.signature,
        confirmedMetadata: dto.metadata,
      };
    }
    
    await this.transactionRepository.save(transaction);

    await this.paymentQueue.add('process-payment', {
      transactionId: transaction.id,
      userOperation: dto.userOperation,
      signature: dto.signature,
    });

    return {
      transactionId: transaction.id,
      status: transaction.status,
      message: 'Payment is being processed',
    };
  }

  async getTransactionStatus(transactionId: string, userId: string) {
    const transaction = await this.transactionRepository.findOne({
      where: { id: transactionId, user: { id: userId } },
      relations: ['merchant'],
    });

    if (!transaction) {
      throw new NotFoundException('Transaction not found');
    }

    return {
      id: transaction.id,
      reference: transaction.reference,
      status: transaction.status,
      amountCrypto: transaction.amountCrypto,
      amountFiat: transaction.amountFiat,
      cryptoTxHash: transaction.cryptoTxHash,
      merchant: {
        businessName: transaction.merchant.businessName,
      },
      createdAt: transaction.createdAt,
      confirmedAt: transaction.confirmedAt,
      settledAt: transaction.settledAt,
    };
  }

  async getUserTransactions(userId: string, limit = 20) {
    return this.transactionRepository.find({
      where: { user: { id: userId } },
      relations: ['merchant'],
      order: { createdAt: 'DESC' },
      take: limit,
    });
  }

  async updateTransactionStatus(
    transactionId: string,
    status: TransactionStatus,
    cryptoTxHash?: string,
  ) {
    const transaction = await this.transactionRepository.findOne({
      where: { id: transactionId },
    });

    if (!transaction) {
      throw new NotFoundException('Transaction not found');
    }

    transaction.status = status;
    if (cryptoTxHash) {
      transaction.cryptoTxHash = cryptoTxHash;
    }
    if (status === TransactionStatus.CONFIRMED) {
      transaction.confirmedAt = new Date();
    }
    if (status === TransactionStatus.SETTLED) {
      transaction.settledAt = new Date();
    }

    return this.transactionRepository.save(transaction);
  }

  async findById(id: string): Promise<Transaction> {
    return this.transactionRepository.findOne({
      where: { id },
      relations: ['user', 'merchant'],
    });
  }
}