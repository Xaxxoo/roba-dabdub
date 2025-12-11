import {
  Entity,
  PrimaryGeneratedColumn,
  Column,
  CreateDateColumn,
  UpdateDateColumn,
  ManyToOne,
  JoinColumn,
} from 'typeorm';
import { User } from '../../auth/entities/user.entity';
import { Merchant } from '../../merchant/entities/merchant.entity';

export enum TransactionStatus {
  PENDING = 'pending',
  PROCESSING = 'processing',
  CONFIRMED = 'confirmed',
  SETTLING = 'settling',
  SETTLED = 'settled',
  FAILED = 'failed',
  EXPIRED = 'expired',
}

export enum TransactionType {
  SCAN_TO_PAY = 'scan_to_pay',
  USERNAME_PAY = 'username_pay',
}

@Entity('transactions')
export class Transaction {
  @PrimaryGeneratedColumn('uuid')
  id: string;

  @Column({ unique: true })
  reference: string;

  @ManyToOne(() => User)
  @JoinColumn()
  user: User;

  @ManyToOne(() => Merchant)
  @JoinColumn()
  merchant: Merchant;

  @Column({ type: 'enum', enum: TransactionType })
  type: TransactionType;

  @Column('decimal', { precision: 18, scale: 6 })
  amountCrypto: number;

  @Column()
  cryptoToken: string; // USDT, USDC, etc.

  @Column('decimal', { precision: 18, scale: 2 })
  amountFiat: number;

  @Column()
  fiatCurrency: string; // NGN

  @Column('decimal', { precision: 10, scale: 6 })
  conversionRate: number;

  @Column({ nullable: true })
  cryptoTxHash: string;

  @Column({ type: 'enum', enum: TransactionStatus, default: TransactionStatus.PENDING })
  status: TransactionStatus;

  @Column({ type: 'jsonb', nullable: true })
  metadata: Record<string, any>;

  @Column({ type: 'timestamp', nullable: true })
  confirmedAt: Date;

  @Column({ type: 'timestamp', nullable: true })
  settledAt: Date;

  @Column({ type: 'timestamp', nullable: true })
  expiresAt: Date;

  @CreateDateColumn()
  createdAt: Date;

  @UpdateDateColumn()
  updatedAt: Date;
}