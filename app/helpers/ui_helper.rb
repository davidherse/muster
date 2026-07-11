# Muster's shadcn-style component recipes. ERB views compose these class
# strings instead of ad-hoc Tailwind so every control shares one design
# language (shadcn/ui variants, mapped to the Muster brand tokens).
module UiHelper
  BUTTON_BASE = "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-md text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:pointer-events-none disabled:opacity-50 cursor-pointer".freeze

  BUTTON_VARIANTS = {
    default: "bg-primary text-primary-foreground shadow hover:bg-primary/90",
    secondary: "bg-secondary text-secondary-foreground shadow-sm hover:bg-secondary/80",
    outline: "border border-input bg-background shadow-sm hover:bg-accent hover:text-accent-foreground",
    ghost: "hover:bg-accent hover:text-accent-foreground",
    destructive: "bg-destructive text-destructive-foreground shadow-sm hover:bg-destructive/90",
    link: "text-primary underline-offset-4 hover:underline"
  }.freeze

  BUTTON_SIZES = {
    default: "h-9 px-4 py-2",
    sm: "h-8 rounded-md px-3 text-xs",
    lg: "h-10 rounded-md px-8"
  }.freeze

  def ui_button(variant: :default, size: :default)
    [ BUTTON_BASE, BUTTON_VARIANTS.fetch(variant), BUTTON_SIZES.fetch(size) ].join(" ")
  end

  def ui_input
    "flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:opacity-50"
  end

  def ui_textarea
    "flex min-h-[60px] w-full rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:opacity-50"
  end

  def ui_select
    "flex h-9 w-full items-center rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:opacity-50"
  end

  def ui_label
    "text-sm font-medium leading-none text-foreground"
  end

  def ui_card
    "rounded-xl border border-border bg-card text-card-foreground shadow-sm"
  end

  def ui_card_header = "flex flex-col space-y-1.5 p-6"
  def ui_card_title = "font-semibold leading-none tracking-tight"
  def ui_card_description = "text-sm text-muted-foreground"
  def ui_card_content = "p-6 pt-0"

  BADGE_BASE = "inline-flex items-center rounded-md border px-2.5 py-0.5 text-xs font-semibold transition-colors".freeze
  BADGE_VARIANTS = {
    default: "border-transparent bg-primary text-primary-foreground",
    secondary: "border-transparent bg-secondary text-secondary-foreground",
    outline: "text-foreground border-border",
    destructive: "border-transparent bg-destructive text-destructive-foreground",
    success: "border-transparent bg-emerald-600 text-white"
  }.freeze

  def ui_badge(variant: :default)
    [ BADGE_BASE, BADGE_VARIANTS.fetch(variant) ].join(" ")
  end

  def ui_alert(variant: :default)
    base = "relative w-full rounded-lg border px-4 py-3 text-sm"
    variant == :destructive ? "#{base} border-destructive/50 text-destructive" : "#{base} border-border bg-card text-foreground"
  end

  def ui_table = "w-full caption-bottom text-sm"
  def ui_table_header_row = "border-b border-border"
  def ui_table_head = "h-10 px-2 text-left align-middle font-medium text-muted-foreground"
  def ui_table_row = "border-b border-border transition-colors hover:bg-muted/50"
  def ui_table_cell = "p-2 align-middle"
end
