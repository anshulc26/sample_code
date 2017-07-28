class AdvanceProductExpirationReminderToWholesalers
  include Sidekiq::Worker
  include Sidetiq::Schedulable

  recurrence { daily }

  def perform(_args)
    product_ids = []
    suppliers = Spree::SupplierProduct.where('status = ? AND is_active = ?', 'active', true).find_each.inject([]) do |arr, supplier_product|
      if supplier_product.expiration_date.present? && supplier_product.expiration_date.to_date == 90.days.from_now.to_date
        arr << supplier_product.supplier
        product_ids << supplier_product.product_id
      end
      arr
    end.uniq

    products = Spree::SupplierProduct.where(id: product_ids)

    if suppliers.any?
      suppliers.each do |supplier|
        InventoryMailer.delay.inventory_product_expiration_reminder(email: supplier.emails, wholesaler_name: supplier.supplier_store.name, products: products)
      end
    end
  end
end
