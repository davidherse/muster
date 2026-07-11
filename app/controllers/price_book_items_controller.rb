class PriceBookItemsController < ApplicationController
  before_action :require_admin

  before_action :set_item, only: %i[ edit update destroy ]

  def index
    @query = params[:q].to_s.strip
    @items = PriceBookItem.ordered
    @items = @items.where("description LIKE :q OR category LIKE :q", q: "%#{PriceBookItem.sanitize_sql_like(@query)}%") if @query.present?
    @items = @items.limit(200)
  end

  def new
    @item = PriceBookItem.new
  end

  def create
    @item = PriceBookItem.new(item_params)
    if @item.save
      redirect_to price_book_items_path, notice: "Price book item added."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @item.update(item_params)
      redirect_to price_book_items_path, notice: "Price book item updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @item.destroy
    redirect_to price_book_items_path, notice: "Price book item removed."
  end

  private

  def set_item
    @item = PriceBookItem.find(params[:id])
  end

  def item_params
    params.expect(price_book_item: [ :category, :description, :item_type, :uom, :unit_cost ])
  end

  def require_admin
    redirect_to root_path, alert: "The price book is managed by Muster administrators." unless Current.user&.admin?
  end

end