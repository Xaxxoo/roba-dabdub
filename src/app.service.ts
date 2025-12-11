import { Injectable } from '@nestjs/common';

@Injectable()
export class AppService {
  getHello(): string {
    return 'Rub a dab dub cos I am about to go for my grub!';
  }
}
