import { Injectable, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import * as QRCode from 'qrcode';
import { Merchant, MerchantStatus } from './entities/merchant.entity';
import { User } from '../auth/entities/user.entity';
import { CreateMerchantDto } from './dto/create-merchant.dto';
import { GenerateQRDto } from './dto/generate-qr.dto';

@Injectable()
export class MerchantService {
  constructor(
    @InjectRepository(Merchant)
    private merchantRepository: Repository<Merchant>,
  ) {}

  async createMerchant(user: User, dto: CreateMerchantDto) {
    const merchantCode = this.generateMerchantCode();
    
    const merchant = this.merchantRepository.create({
      user,
      businessName: dto.businessName,
      merchantCode,
      bankDetails: dto.bankDetails,
      status: MerchantStatus.PENDING,
    });

    return this.merchantRepository.save(merchant);
  }

  async findByUser(userId: string): Promise<Merchant> {
    return this.merchantRepository.findOne({
      where: { user: { id: userId } },
      relations: ['user'],
    });
  }

  async findByMerchantCode(merchantCode: string): Promise<Merchant> {
    return this.merchantRepository.findOne({
      where: { merchantCode },
      relations: ['user'],
    });
  }

  async generateQRCode(merchant: Merchant, dto: GenerateQRDto) {
    const reference = dto.reference || this.generateReference();
    
    const paymentData = {
      type: 'payment_request',
      merchantId: merchant.id,
      merchantCode: merchant.merchantCode,
      businessName: merchant.businessName,
      amount: dto.amount,
      currency: dto.currency,
      reference,
      description: dto.description,
      apiEndpoint: `${process.env.API_URL || 'http://localhost:3000'}/api/v1/payment/initiate`,
      timestamp: new Date().toISOString(),
      expiresAt: new Date(Date.now() + 15 * 60 * 1000).toISOString(), // 15 min expiry
    };

    const qrDataString = JSON.stringify(paymentData);
    const qrCodeDataURL = await QRCode.toDataURL(qrDataString, {
      width: 400,
      margin: 2,
    });

    return {
      qrCode: qrCodeDataURL,
      qrData: paymentData,
      reference,
    };
  }

  private generateMerchantCode(): string {
    return `MERCH${Date.now()}${Math.random().toString(36).substr(2, 6).toUpperCase()}`;
  }

  private generateReference(): string {
    return `REF${Date.now()}${Math.random().toString(36).substr(2, 9).toUpperCase()}`;
  }
}