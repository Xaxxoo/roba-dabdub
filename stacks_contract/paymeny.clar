;; ============================================================================
;; PAYMENT WALLET - CLARITY SMART CONTRACT
;; Bitcoin L2 Payment System on Stacks
;; ============================================================================

;; Title: Payment Wallet
;; Version: 1.0.0
;; Description: Multi-currency payment wallet supporting deposits, merchant payments, and P2P transfers

;; ============================================================================
;; CONSTANTS
;; ============================================================================

;; Contract owner
(define-constant contract-owner tx-sender)

;; Error codes
(define-constant err-owner-only (err u100))
(define-constant err-insufficient-balance (err u101))
(define-constant err-invalid-amount (err u102))
(define-constant err-invalid-address (err u103))
(define-constant err-payment-already-processed (err u104))
(define-constant err-self-transfer (err u105))
(define-constant err-contract-paused (err u106))
(define-constant err-invalid-fee (err u107))

;; Payment types
(define-constant payment-type-merchant u0)
(define-constant payment-type-user-to-user u1)

;; Fee constants (in basis points)
(define-constant max-fee-bps u1000) ;; 10% maximum
(define-constant bps-divisor u10000)

;; ============================================================================
;; DATA VARIABLES
;; ============================================================================

;; Platform fee wallet (receives fees)
(define-data-var platform-wallet principal contract-owner)

;; Platform fee in basis points (e.g., 50 = 0.5%)
(define-data-var platform-fee-bps uint u50)

;; Contract pause state
(define-data-var contract-paused bool false)

;; Total balance in contract (for accounting)
(define-data-var total-balance uint u0)

;; ============================================================================
;; DATA MAPS
;; ============================================================================

;; User balances (principal => balance)
(define-map balances principal uint)

;; Processed payments (payment-reference => bool)
(define-map processed-payments (buff 32) bool)

;; User nonces for replay protection (principal => nonce)
(define-map nonces principal uint)

;; ============================================================================
;; PRIVATE FUNCTIONS
;; ============================================================================

;; Check if contract is paused
(define-private (check-paused)
  (if (var-get contract-paused)
    err-contract-paused
    (ok true)))

;; Calculate fee amount
(define-private (calculate-fee (amount uint))
  (/ (* amount (var-get platform-fee-bps)) bps-divisor))

;; Get balance with default 0
(define-private (get-balance-or-default (user principal))
  (default-to u0 (map-get? balances user)))

;; ============================================================================
;; READ-ONLY FUNCTIONS
;; ============================================================================

;; Get user balance
(define-read-only (balance-of (user principal))
  (ok (get-balance-or-default user)))

;; Check if payment has been processed
(define-read-only (is-payment-processed (payment-reference (buff 32)))
  (ok (default-to false (map-get? processed-payments payment-reference))))

;; Get total balance in contract
(define-read-only (get-total-balance)
  (ok (var-get total-balance)))

;; Get platform fee in basis points
(define-read-only (get-platform-fee-bps)
  (ok (var-get platform-fee-bps)))

;; Get platform wallet
(define-read-only (get-platform-wallet)
  (ok (var-get platform-wallet)))

;; Get user nonce
(define-read-only (get-nonce (user principal))
  (ok (default-to u0 (map-get? nonces user))))

;; Check if contract is paused
(define-read-only (is-paused)
  (ok (var-get contract-paused)))

;; ============================================================================
;; DEPOSIT FUNCTIONS
;; ============================================================================

;; Deposit STX to wallet balance
;; Note: In production, you'd integrate with sBTC or other stablecoins
(define-public (deposit (amount uint))
  (let
    (
      (sender tx-sender)
      (current-balance (get-balance-or-default sender))
    )
    ;; Check contract not paused
    (try! (check-paused))
    
    ;; Validate amount
    (asserts! (> amount u0) err-invalid-amount)
    
    ;; Transfer STX from sender to contract
    (try! (stx-transfer? amount sender (as-contract tx-sender)))
    
    ;; Update sender balance
    (map-set balances sender (+ current-balance amount))
    
    ;; Update total balance
    (var-set total-balance (+ (var-get total-balance) amount))
    
    ;; Emit deposit event via print
    (print {
      event: "deposit",
      user: sender,
      amount: amount,
      new-balance: (+ current-balance amount),
      timestamp: block-height
    })
    
    (ok true)))

;; Deposit on behalf of another user
(define-public (deposit-for (user principal) (amount uint))
  (let
    (
      (sender tx-sender)
      (current-balance (get-balance-or-default user))
    )
    ;; Check contract not paused
    (try! (check-paused))
    
    ;; Validate inputs
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (not (is-eq user sender)) err-self-transfer)
    
    ;; Transfer STX from sender to contract
    (try! (stx-transfer? amount sender (as-contract tx-sender)))
    
    ;; Update user balance
    (map-set balances user (+ current-balance amount))
    
    ;; Update total balance
    (var-set total-balance (+ (var-get total-balance) amount))
    
    ;; Emit deposit event
    (print {
      event: "deposit-for",
      depositor: sender,
      user: user,
      amount: amount,
      new-balance: (+ current-balance amount),
      timestamp: block-height
    })
    
    (ok true)))

;; ============================================================================
;; PAYMENT FUNCTIONS
;; ============================================================================

;; Process a payment (merchant or P2P)
(define-public (process-payment 
  (from principal)
  (to principal)
  (amount uint)
  (payment-reference (buff 32))
  (payment-type uint))
  (let
    (
      (sender-balance (get-balance-or-default from))
      (receiver-balance (get-balance-or-default to))
      (platform-balance (get-balance-or-default (var-get platform-wallet)))
      (fee (calculate-fee amount))
      (amount-after-fee (- amount fee))
    )
    ;; Only contract owner can process payments (backend)
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    ;; Check contract not paused
    (try! (check-paused))
    
    ;; Validate inputs
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (not (is-eq from to)) err-self-transfer)
    
    ;; Check payment not already processed
    (asserts! 
      (is-none (map-get? processed-payments payment-reference))
      err-payment-already-processed)
    
    ;; Check sender has sufficient balance
    (asserts! (>= sender-balance amount) err-insufficient-balance)
    
    ;; Mark payment as processed
    (map-set processed-payments payment-reference true)
    
    ;; Update sender balance
    (map-set balances from (- sender-balance amount))
    
    ;; Update receiver balance (after fee)
    (map-set balances to (+ receiver-balance amount-after-fee))
    
    ;; Update platform wallet balance (fee)
    (if (> fee u0)
      (map-set balances (var-get platform-wallet) (+ platform-balance fee))
      true)
    
    ;; Emit payment event
    (print {
      event: "payment-processed",
      from: from,
      to: to,
      amount: amount,
      fee: fee,
      amount-after-fee: amount-after-fee,
      payment-reference: payment-reference,
      payment-type: payment-type,
      timestamp: block-height
    })
    
    (ok true)))

;; ============================================================================
;; WITHDRAWAL FUNCTIONS
;; ============================================================================

;; Withdraw from wallet balance
(define-public (withdraw (amount uint))
  (let
    (
      (sender tx-sender)
      (current-balance (get-balance-or-default sender))
    )
    ;; Check contract not paused
    (try! (check-paused))
    
    ;; Validate amount
    (asserts! (> amount u0) err-invalid-amount)
    
    ;; Check sufficient balance
    (asserts! (>= current-balance amount) err-insufficient-balance)
    
    ;; Update sender balance
    (map-set balances sender (- current-balance amount))
    
    ;; Update total balance
    (var-set total-balance (- (var-get total-balance) amount))
    
    ;; Transfer STX from contract to sender
    (try! (as-contract (stx-transfer? amount tx-sender sender)))
    
    ;; Emit withdrawal event
    (print {
      event: "withdrawal",
      user: sender,
      amount: amount,
      new-balance: (- current-balance amount),
      timestamp: block-height
    })
    
    (ok true)))

;; Withdraw all balance
(define-public (withdraw-all)
  (let
    (
      (sender tx-sender)
      (amount (get-balance-or-default sender))
    )
    ;; Check contract not paused
    (try! (check-paused))
    
    ;; Validate amount
    (asserts! (> amount u0) err-invalid-amount)
    
    ;; Update sender balance to zero
    (map-delete balances sender)
    
    ;; Update total balance
    (var-set total-balance (- (var-get total-balance) amount))
    
    ;; Transfer STX from contract to sender
    (try! (as-contract (stx-transfer? amount tx-sender sender)))
    
    ;; Emit withdrawal event
    (print {
      event: "withdrawal-all",
      user: sender,
      amount: amount,
      new-balance: u0,
      timestamp: block-height
    })
    
    (ok true)))

;; ============================================================================
;; ADMIN FUNCTIONS
;; ============================================================================

;; Set platform fee
(define-public (set-platform-fee (new-fee-bps uint))
  (begin
    ;; Only owner can update
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    ;; Validate fee
    (asserts! (<= new-fee-bps max-fee-bps) err-invalid-fee)
    
    ;; Update fee
    (var-set platform-fee-bps new-fee-bps)
    
    ;; Emit event
    (print {
      event: "fee-updated",
      new-fee-bps: new-fee-bps,
      timestamp: block-height
    })
    
    (ok true)))

;; Set platform wallet
(define-public (set-platform-wallet (new-wallet principal))
  (begin
    ;; Only owner can update
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    ;; Update wallet
    (var-set platform-wallet new-wallet)
    
    ;; Emit event
    (print {
      event: "wallet-updated",
      new-wallet: new-wallet,
      timestamp: block-height
    })
    
    (ok true)))

;; Pause contract
(define-public (pause)
  (begin
    ;; Only owner can pause
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    ;; Set paused state
    (var-set contract-paused true)
    
    ;; Emit event
    (print {
      event: "contract-paused",
      timestamp: block-height
    })
    
    (ok true)))

;; Unpause contract
(define-public (unpause)
  (begin
    ;; Only owner can unpause
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    ;; Set unpaused state
    (var-set contract-paused false)
    
    ;; Emit event
    (print {
      event: "contract-unpaused",
      timestamp: block-height
    })
    
    (ok true)))

;; Emergency withdrawal (admin only)
(define-public (emergency-withdraw (amount uint) (recipient principal))
  (begin
    ;; Only owner
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    ;; Transfer STX
    (try! (as-contract (stx-transfer? amount tx-sender recipient)))
    
    ;; Emit event
    (print {
      event: "emergency-withdrawal",
      amount: amount,
      recipient: recipient,
      timestamp: block-height
    })
    
    (ok true)))

