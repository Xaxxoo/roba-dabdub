import {
  Entity,
  PrimaryGeneratedColumn,
  Column,
  CreateDateColumn,
  UpdateDateColumn,
  OneToOne,
  JoinColumn,
} from 'typeorm';
import { User } from '../../auth/entities/user.entity';

export enum MerchantStatus {
  PENDING = 'pending',
  ACTIVE = 'active',
  SUSPENDED = 'suspended',
}

@Entity('merchants')
export class Merchant {
  @PrimaryGeneratedColumn('uuid')
  id: string;

  @OneToOne(() => User)
  @JoinColumn()
  user: User;

  @Column()
  businessName: string;

  @Column({ unique: true })
  merchantCode: string;

  @Column({ type: 'enum', enum: MerchantStatus, default: MerchantStatus.PENDING })
  status: MerchantStatus;

  @Column({ type: 'jsonb' })
  bankDetails: {
    accountNumber: string;
    accountName: string;
    bankCode: string;
    bankName: string;
  };

  @Column({ type: 'jsonb', nullable: true })
  kycDetails: Record<string, any>;

  @Column({ default: false })
  kycVerified: boolean;

  @CreateDateColumn()
  createdAt: Date;

  @UpdateDateColumn()
  updatedAt: Date;
}