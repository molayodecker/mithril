# Worker payouts in Ghana

## Currently supported

Mithril reserves worker funds in PostgreSQL and initiates Paystack transfers from
the **Paystack balance**. Paystack supports `mobile_money` for Ghana MoMo wallets
and `ghipss` for Ghana bank accounts. Legacy clients submitting `nuban` for a
GHS bank account are normalized to `ghipss` before the Paystack API call.

Paystack's `/transfer` API **cannot debit Stanbic Business Online directly**;
its transfer source is the Paystack balance. Never represent a Paystack
withdrawal as a direct Stanbic-funded payout.

For customer payments already collected by Paystack, consider Paystack Manual
Payouts (settlements into the Paystack balance), subject to Paystack approval.
This avoids a separate MoMo top-up for those collected funds. Confirm settlement
timing and any limitations with Paystack before switching live settings.

## Stanbic direct disbursements: prerequisites before coding the adapter

Business Online access is not proof of host-to-host/API authorization. Obtain
from Stanbic Ghana, in writing:

1. Production and test API/host-to-host specifications, credentials and network
   requirements, including the appropriate corporate account permissions.
2. Whether the service supports individual and batch GhIPSS bank payouts **and**
   MTN/Telecel/AT MoMo disbursements; if not, an approved MoMo payout partner.
3. Beneficiary verification, transaction limits, fees, processing times,
   idempotency/reference rules, and status query or callback behavior.
4. Reversal and dispute procedures, statements/reconciliation feeds, and
   regulatory/contractual eligibility for marketplace worker payouts.

Until these items are available, do not enable a `stanbic` payout provider or
send live account funds through an assumed endpoint.

## Required implementation for a future Stanbic adapter

- Keep an immutable payout destination snapshot (provider, beneficiary, account
  fingerprint, currency) attached to each initiated withdrawal.
- Reserve balances atomically; guarantee uniqueness on the client withdrawal
  reference, and prevent two concurrent requests from spending the same wallet.
- Record the selected provider before dispatch and retry using the **same**
  provider reference; never switch providers on an uncertain result.
- Treat network timeouts as `processing`/unknown, not failed. Reconcile against
  the bank before releasing reserved funds or attempting another payout.
- Authenticate bank callbacks, confirm amount/currency/reference, and make
  success/failure/reversal transitions idempotent.
- Require explicit staff-approved provider activation and a reconciliation
  dashboard before the first Stanbic production disbursement.

Paystack documentation:

- https://paystack.com/docs/transfers/creating-transfer-recipients/
- https://paystack.com/docs/transfers/single-transfers/
- https://support.paystack.com/en/articles/2131074
