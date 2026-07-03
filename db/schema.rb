# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_03_225542) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "estimate_line_items", force: :cascade do |t|
    t.text "assumptions"
    t.string "confidence"
    t.datetime "created_at", null: false
    t.text "description", null: false
    t.integer "estimate_section_id", null: false
    t.string "item_type"
    t.integer "position", null: false
    t.decimal "quantity", precision: 12, scale: 3
    t.decimal "total", precision: 14, scale: 2
    t.decimal "unit_cost", precision: 12, scale: 2
    t.string "uom"
    t.datetime "updated_at", null: false
    t.index ["estimate_section_id"], name: "index_estimate_line_items_on_estimate_section_id"
  end

  create_table "estimate_sections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "estimate_id", null: false
    t.string "name", null: false
    t.integer "position", null: false
    t.datetime "updated_at", null: false
    t.index ["estimate_id"], name: "index_estimate_sections_on_estimate_id"
  end

  create_table "estimate_templates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.json "sections", default: [], null: false
    t.datetime "updated_at", null: false
  end

  create_table "estimates", force: :cascade do |t|
    t.json "assessment", default: {}, null: false
    t.string "building_type"
    t.json "costed_sections", default: [], null: false
    t.datetime "created_at", null: false
    t.text "error_message"
    t.integer "estimate_template_id"
    t.string "floor_area"
    t.string "name", null: false
    t.json "plan_summary"
    t.integer "progress", default: 0
    t.string "progress_note"
    t.text "prompt"
    t.json "questionnaire", default: {}, null: false
    t.string "status", default: "draft", null: false
    t.decimal "total", precision: 14, scale: 2
    t.decimal "total_high", precision: 14, scale: 2
    t.decimal "total_low", precision: 14, scale: 2
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["estimate_template_id"], name: "index_estimates_on_estimate_template_id"
    t.index ["user_id"], name: "index_estimates_on_user_id"
  end

  create_table "price_book_items", force: :cascade do |t|
    t.string "category", null: false
    t.json "context", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "description", null: false
    t.string "item_type"
    t.integer "sample_count", default: 1
    t.string "source"
    t.string "source_kind", default: "base", null: false
    t.decimal "unit_cost", precision: 12, scale: 2, null: false
    t.string "uom"
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["user_id"], name: "index_price_book_items_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "training_documents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_message"
    t.json "extraction", default: {}, null: false
    t.string "name"
    t.date "priced_on"
    t.json "questionnaire", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_training_documents_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "activated_at"
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "name"
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "estimate_line_items", "estimate_sections"
  add_foreign_key "estimate_sections", "estimates"
  add_foreign_key "estimates", "estimate_templates"
  add_foreign_key "estimates", "users"
  add_foreign_key "price_book_items", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "training_documents", "users"
end
