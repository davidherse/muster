class PriceBookItemsController < ApplicationController
  before_action :require_admin

  before_action :set_item, only: %i[ edit update destroy ]

  PER_PAGE = 25

  def index
    @query = params[:q].to_s.strip
    scope = PriceBookItem.ordered
    scope = scope.where("description LIKE :q OR category LIKE :q", q: "%#{PriceBookItem.sanitize_sql_like(@query)}%") if @query.present?
    scope = scope.where(category: params[:category]) if params[:category].present?
    scope = scope.where(source_kind: params[:kind]) if params[:kind].present?
    @categories = PriceBookItem.distinct.order(:category).pluck(:category)
    @total_count = scope.count
    @page = [ params[:page].to_i, 1 ].max
    @total_pages = [ (@total_count / PER_PAGE.to_f).ceil, 1 ].max
    @page = @total_pages if @page > @total_pages
    @items = scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
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