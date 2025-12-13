;; ============================================================================
;; MULTI-TOKEN PAYMENT WALLET - CLARITY SMART CONTRACT
;; Supports sBTC, xUSD, USDA, and other SIP-010 tokens
;; ============================================================================

;; ============================================================================
;; TRAITS
;; ============================================================================

;; SIP-010 Fungible Token Trait
(use-trait sip-010-trait 'SP3FBR2AGK5H9QBDH3EEN6DF8EK8JY7RX8QJ5SVTE.sip-010-trait-ft-standard.sip-010-trait)

;; ============================================================================
;; CONSTANTS
;; ============================================================================

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
(define-constant err-token-not-whitelisted (err u108))
(define-constant err-transfer-failed (err u109))

;; Payment types
(define-constant payment-type-merchant u0)
(define-constant payment-type-user-to-user u1)

;; Fee constants
(define-constant max-fee-bps u1000)
(define-constant bps-divisor u10000)

;; ============================================================================
;; DATA VARIABLES
;; ============================================================================

(define-data-var platform-wallet principal contract-owner)
(define-data-var platform-fee-bps uint u50)
(define-data-var contract-paused bool false)

;; ============================================================================
;; DATA MAPS
;; ============================================================================

;; User balances per token (user + token-contract => balance)
(define-map balances 
  { user: principal, token: principal } 
  uint)

;; Whitelisted tokens (token-contract => enabled)
(define-map whitelisted-tokens principal bool)

;; Token metadata (token-contract => {name, symbol, decimals})
(define-map token-info 
  principal 
  { 
    name: (string-ascii 32),
    symbol: (string-ascii 10),
    decimals: uint 
  })

;; Processed payments
(define-map processed-payments (buff 32) bool)

;; User nonces
(define-map nonces principal uint)

;; ============================================================================
;; PRIVATE FUNCTIONS
;; ============================================================================

(define-private (check-paused)
  (if (var-get contract-paused)
    err-contract-paused
    (ok true)))

(define-private (calculate-fee (amount uint))
  (/ (* amount (var-get platform-fee-bps)) bps-divisor))

(define-private (get-balance-or-default (user principal) (token principal))
  (default-to u0 (map-get? balances { user: user, token: token })))

(define-private (is-token-whitelisted (token principal))
  (default-to false (map-get? whitelisted-tokens token)))

;; ============================================================================
;; READ-ONLY FUNCTIONS
;; ============================================================================

;; Get user balance for specific token
(define-read-only (balance-of (user principal) (token principal))
  (ok (get-balance-or-default user token)))

;; Get all user balances (frontend would call this for each token)
(define-read-only (get-user-balances (user principal) (tokens (list 10 principal)))
  (ok (map get-token-balance 
    (map make-balance-tuple tokens))))

;; Helper for mapping
(define-private (make-balance-tuple (token principal))
  { user: tx-sender, token: token })

(define-private (get-token-balance (data { user: principal, token: principal }))
  {
    token: (get token data),
    balance: (get-balance-or-default (get user data) (get token data))
  })

;; Check if token is whitelisted
(define-read-only (is-whitelisted (token principal))
  (ok (is-token-whitelisted token)))

;; Get token info
(define-read-only (get-token-info (token principal))
  (ok (map-get? token-info token)))

;; Check if payment processed
(define-read-only (is-payment-processed (payment-reference (buff 32)))
  (ok (default-to false (map-get? processed-payments payment-reference))))

;; ============================================================================
;; DEPOSIT FUNCTIONS
;; ============================================================================

;; Deposit SIP-010 token
(define-public (deposit (token-contract <sip-010-trait>) (amount uint))
  (let
    (
      (sender tx-sender)
      (token (contract-of token-contract))
      (current-balance (get-balance-or-default sender token))
    )
    ;; Check contract not paused
    (try! (check-paused))
    
    ;; Validate amount
    (asserts! (> amount u0) err-invalid-amount)
    
    ;; Check token is whitelisted
    (asserts! (is-token-whitelisted token) err-token-not-whitelisted)
    
    ;; Transfer tokens from sender to contract
    (match (contract-call? token-contract transfer 
            amount 
            sender 
            (as-contract tx-sender) 
            none)
      success (begin
        ;; Update balance
        (map-set balances 
          { user: sender, token: token }
          (+ current-balance amount))
        
        ;; Emit event
        (print {
          event: "deposit",
          user: sender,
          token: token,
          amount: amount,
          new-balance: (+ current-balance amount),
          timestamp: block-height
        })
        
        (ok true))
      error err-transfer-failed)))

;; Deposit for another user
(define-public (deposit-for 
  (token-contract <sip-010-trait>) 
  (user principal) 
  (amount uint))
  (let
    (
      (sender tx-sender)
      (token (contract-of token-contract))
      (current-balance (get-balance-or-default user token))
    )
    ;; Check contract not paused
    (try! (check-paused))
    
    ;; Validate inputs
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (not (is-eq user sender)) err-self-transfer)
    (asserts! (is-token-whitelisted token) err-token-not-whitelisted)
    
    ;; Transfer tokens
    (match (contract-call? token-contract transfer 
            amount 
            sender 
            (as-contract tx-sender) 
            none)
      success (begin
        ;; Update balance
        (map-set balances 
          { user: user, token: token }
          (+ current-balance amount))
        
        ;; Emit event
        (print {
          event: "deposit-for",
          depositor: sender,
          user: user,
          token: token,
          amount: amount,
          new-balance: (+ current-balance amount),
          timestamp: block-height
        })
        
        (ok true))
      error err-transfer-failed)))

;; ============================================================================
;; PAYMENT FUNCTIONS
;; ============================================================================

;; Process payment with specific token
(define-public (process-payment
  (token-contract <sip-010-trait>)
  (from principal)
  (to principal)
  (amount uint)
  (payment-reference (buff 32))
  (payment-type uint))
  (let
    (
      (token (contract-of token-contract))
      (sender-balance (get-balance-or-default from token))
      (receiver-balance (get-balance-or-default to token))
      (platform-balance (get-balance-or-default (var-get platform-wallet) token))
      (fee (calculate-fee amount))
      (amount-after-fee (- amount fee))
    )
    ;; Only contract owner can process payments
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    ;; Check contract not paused
    (try! (check-paused))
    
    ;; Validate inputs
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (not (is-eq from to)) err-self-transfer)
    (asserts! (is-token-whitelisted token) err-token-not-whitelisted)
    
    ;; Check payment not processed
    (asserts! 
      (is-none (map-get? processed-payments payment-reference))
      err-payment-already-processed)
    
    ;; Check sufficient balance
    (asserts! (>= sender-balance amount) err-insufficient-balance)
    
    ;; Mark as processed
    (map-set processed-payments payment-reference true)
    
    ;; Update balances
    (map-set balances 
      { user: from, token: token }
      (- sender-balance amount))
    
    (map-set balances 
      { user: to, token: token }
      (+ receiver-balance amount-after-fee))
    
    ;; Update platform balance
    (if (> fee u0)
      (map-set balances 
        { user: (var-get platform-wallet), token: token }
        (+ platform-balance fee))
      true)
    
    ;; Emit event
    (print {
      event: "payment-processed",
      from: from,
      to: to,
      token: token,
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

;; Withdraw specific token
(define-public (withdraw (token-contract <sip-010-trait>) (amount uint))
  (let
    (
      (sender tx-sender)
      (token (contract-of token-contract))
      (current-balance (get-balance-or-default sender token))
    )
    ;; Check contract not paused
    (try! (check-paused))
    
    ;; Validate amount
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (>= current-balance amount) err-insufficient-balance)
    
    ;; Update balance
    (map-set balances 
      { user: sender, token: token }
      (- current-balance amount))
    
    ;; Transfer tokens from contract to sender
    (match (as-contract (contract-call? token-contract transfer 
            amount 
            tx-sender 
            sender 
            none))
      success (begin
        ;; Emit event
        (print {
          event: "withdrawal",
          user: sender,
          token: token,
          amount: amount,
          new-balance: (- current-balance amount),
          timestamp: block-height
        })
        
        (ok true))
      error err-transfer-failed)))

;; Withdraw all of specific token
(define-public (withdraw-all (token-contract <sip-010-trait>))
  (let
    (
      (sender tx-sender)
      (token (contract-of token-contract))
      (amount (get-balance-or-default sender token))
    )
    ;; Check contract not paused
    (try! (check-paused))
    
    ;; Validate amount
    (asserts! (> amount u0) err-invalid-amount)
    
    ;; Delete balance
    (map-delete balances { user: sender, token: token })
    
    ;; Transfer tokens
    (match (as-contract (contract-call? token-contract transfer 
            amount 
            tx-sender 
            sender 
            none))
      success (begin
        ;; Emit event
        (print {
          event: "withdrawal-all",
          user: sender,
          token: token,
          amount: amount,
          new-balance: u0,
          timestamp: block-height
        })
        
        (ok true))
      error err-transfer-failed)))

;; ============================================================================
;; ADMIN FUNCTIONS
;; ============================================================================

;; Whitelist a token
(define-public (whitelist-token 
  (token principal) 
  (name (string-ascii 32))
  (symbol (string-ascii 10))
  (decimals uint))
  (begin
    ;; Only owner
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    ;; Add to whitelist
    (map-set whitelisted-tokens token true)
    
    ;; Store token info
    (map-set token-info token {
      name: name,
      symbol: symbol,
      decimals: decimals
    })
    
    ;; Emit event
    (print {
      event: "token-whitelisted",
      token: token,
      name: name,
      symbol: symbol,
      decimals: decimals,
      timestamp: block-height
    })
    
    (ok true)))

;; Remove token from whitelist
(define-public (remove-token (token principal))
  (begin
    ;; Only owner
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    ;; Remove from whitelist
    (map-delete whitelisted-tokens token)
    
    ;; Emit event
    (print {
      event: "token-removed",
      token: token,
      timestamp: block-height
    })
    
    (ok true)))

;; Set platform fee
(define-public (set-platform-fee (new-fee-bps uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (<= new-fee-bps max-fee-bps) err-invalid-fee)
    
    (var-set platform-fee-bps new-fee-bps)
    
    (print {
      event: "fee-updated",
      new-fee-bps: new-fee-bps,
      timestamp: block-height
    })
    
    (ok true)))

;; Set platform wallet
(define-public (set-platform-wallet (new-wallet principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    (var-set platform-wallet new-wallet)
    
    (print {
      event: "wallet-updated",
      new-wallet: new-wallet,
      timestamp: block-height
    })
    
    (ok true)))

;; Pause/unpause
(define-public (pause)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set contract-paused true)
    (print { event: "paused", timestamp: block-height })
    (ok true)))

(define-public (unpause)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set contract-paused false)
    (print { event: "unpaused", timestamp: block-height })
    (ok true)))

;; ============================================================================
;; TOKEN CONTRACT ADDRESSES (Stacks Mainnet)
;; ============================================================================

;; Example token addresses to whitelist:
;;
;; sBTC (Synthetic Bitcoin):
;; SP3K8BC0PPEVCV7NZ6QSRWPQ2JE9E5B6N3PA0KBR9.token-sbtc
;;
;; xUSD (Stablecoin):
;; SP2C2YFP12AJZB4MABJBAJ55XECVS7E4PMMZ89YZR.usda-token
;;
;; USDA (Another Stablecoin):
;; SP2C2YFP12AJZB4MABJBAJ55XECVS7E4PMMZ89YZR.usda-token
;;
;; STX (Native token - handled differently):
;; Can be integrated via separate functions

;; ============================================================================
;; DEPLOYMENT & INITIALIZATION
;; ============================================================================

;; After deployment, call these functions to initialize:
;;
;; 1. Whitelist sBTC:
;; (contract-call? .multi-token-wallet whitelist-token 
;;   'SP3K8BC0PPEVCV7NZ6QSRWPQ2JE9E5B6N3PA0KBR9.token-sbtc
;;   "Synthetic Bitcoin"
;;   "sBTC"
;;   u8)
;;
;; 2. Whitelist xUSD:
;; (contract-call? .multi-token-wallet whitelist-token 
;;   'SP2C2YFP12AJZB4MABJBAJ55XECVS7E4PMMZ89YZR.xbtc-token
;;   "xUSD Stablecoin"
;;   "xUSD"
;;   u6)
;;
;; 3. Set platform wallet:
;; (contract-call? .multi-token-wallet set-platform-wallet 'YOUR-PLATFORM-WALLET)
;;
;; 4. Set platform fee (0.5%):
;; (contract-call? .multi-token-wallet set-platform-fee u50)