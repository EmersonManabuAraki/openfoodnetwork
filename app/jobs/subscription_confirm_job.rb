require 'open_food_network/subscription_summarizer'

# Confirms orders of unconfirmed proxy orders in recently closed Order Cycles
class SubscriptionConfirmJob
  def perform
    confirm_proxy_orders!
  end

  private

  delegate :record_order, :record_success, :record_issue, to: :summarizer
  delegate :record_and_log_error, :send_confirmation_summary_emails, to: :summarizer

  def summarizer
    @summarizer ||= OpenFoodNetwork::SubscriptionSummarizer.new
  end

  def confirm_proxy_orders!
    # Fetch all unconfirmed proxy orders
    unconfirmed_proxy_orders_ids = unconfirmed_proxy_orders.pluck(:id)

    # Mark these proxy orders as confirmed
    unconfirmed_proxy_orders.update_all(confirmed_at: Time.zone.now)

    # Confirm these proxy orders
    ProxyOrder.where(id: unconfirmed_proxy_orders_ids).each do |proxy_order|
      confirm_order!(proxy_order.order)
    end

    send_confirmation_summary_emails
  end

  def unconfirmed_proxy_orders
    ProxyOrder.not_canceled.where('confirmed_at IS NULL AND placed_at IS NOT NULL')
      .joins(:order_cycle).merge(recently_closed_order_cycles)
      .joins(:order).merge(Spree::Order.complete.not_state('canceled'))
  end

  def recently_closed_order_cycles
    OrderCycle.closed.where('order_cycles.orders_close_at BETWEEN (?) AND (?) OR order_cycles.updated_at BETWEEN (?) AND (?)', 1.hour.ago, Time.zone.now, 1.hour.ago, Time.zone.now)
  end

  # It sets up payments, processes payments and sends confirmation emails
  def confirm_order!(order)
    record_order(order)

    setup_payment!(order) if order.payment_required?
    return send_failed_payment_email(order) if order.errors.present?

    order.process_payments! if order.payment_required?
    return send_failed_payment_email(order) if order.errors.present?

    send_confirmation_email(order)
  end

  def setup_payment!(order)
    Subscriptions::PaymentSetup.new(order).call!
  end

  def send_confirmation_email(order)
    order.update!
    record_success(order)
    SubscriptionMailer.confirmation_email(order).deliver
  end

  def send_failed_payment_email(order)
    order.update!
    record_and_log_error(:failed_payment, order)
    SubscriptionMailer.failed_payment_email(order).deliver
  end
end
