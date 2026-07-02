require "test_helper"

class PriceBookItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
    @item = PriceBookItem.create!(category: "Concrete Works", description: "Concrete pump hire", item_type: "Eq", uom: "day", unit_cost: 950)
  end

  test "index searches" do
    get price_book_items_url(q: "pump")
    assert_response :success
    assert_match "Concrete pump hire", response.body
  end

  test "create and update" do
    post price_book_items_url, params: { price_book_item: { category: "Tiling", description: "Wall tiling labour", item_type: "Sub", uom: "m2", unit_cost: 85 } }
    assert_redirected_to price_book_items_url

    patch price_book_item_url(@item), params: { price_book_item: { unit_cost: 999 } }
    assert_equal 999.to_d, @item.reload.unit_cost
  end
end
