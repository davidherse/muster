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

  # Lucide icons (lucide.dev — the icon set shadcn/ui ships with), inlined as
  # SVG so they inherit currentColor from the design tokens. Add paths here
  # as needed.
  ICONS = {
    "file-text" => '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M10 9H8"/><path d="M16 13H8"/><path d="M16 17H8"/>',
    "graduation-cap" => '<path d="M21.42 10.922a1 1 0 0 0-.019-1.838L12.83 5.18a2 2 0 0 0-1.66 0L2.6 9.08a1 1 0 0 0 0 1.832l8.57 3.908a2 2 0 0 0 1.66 0z"/><path d="M22 10v6"/><path d="M6 12.5V16a6 3 0 0 0 12 0v-3.5"/>',
    "book-open" => '<path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z"/><path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z"/>',
    "log-out" => '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" x2="9" y1="12" y2="12"/>',
    "plus" => '<path d="M5 12h14"/><path d="M12 5v14"/>',
    "download" => '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" x2="12" y1="15" y2="3"/>',
    "trash-2" => '<path d="M3 6h18"/><path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"/><path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"/><line x1="10" x2="10" y1="11" y2="17"/><line x1="14" x2="14" y1="11" y2="17"/>',
    "chevron-right" => '<path d="m9 18 6-6-6-6"/>',
    "upload" => '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" x2="12" y1="3" y2="15"/>',
    "search" => '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
    "check" => '<path d="M20 6 9 17l-5-5"/>',
    "layout-list" => '<rect width="7" height="7" x="3" y="3" rx="1"/><rect width="7" height="7" x="3" y="14" rx="1"/><path d="M14 4h7"/><path d="M14 9h7"/><path d="M14 15h7"/><path d="M14 20h7"/>',
    "panel-left" => '<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M9 3v18"/>',
    "users" => '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>'
  }.freeze

  def ui_icon(name, css: "size-4")
    paths = ICONS.fetch(name)
    %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="#{css}" aria-hidden="true">#{paths}</svg>).html_safe
  end

  # shadcn Avatar anatomy: container + fallback with initials.
  def ui_avatar = "relative flex size-8 shrink-0 overflow-hidden rounded-full"
  def ui_avatar_fallback = "flex size-full items-center justify-center rounded-full bg-primary text-primary-foreground text-xs font-semibold"

  def ui_initials(name)
    name.to_s.split.first(2).map { |w| w[0] }.join.upcase.presence || "?"
  end

  # shadcn DropdownMenu anatomy (content + item classes).
  def ui_dropdown_content = "z-50 min-w-[10rem] overflow-hidden rounded-md border border-border bg-popover p-1 text-popover-foreground shadow-md"
  def ui_dropdown_item = "relative flex w-full cursor-pointer select-none items-center gap-2 rounded-sm px-2 py-1.5 text-sm outline-none hover:bg-accent hover:text-accent-foreground"

  def ui_table = "w-full caption-bottom text-sm"
  def ui_table_header_row = "border-b border-border"
  def ui_table_head = "h-10 px-2 text-left align-middle font-medium text-muted-foreground"
  def ui_table_row = "border-b border-border transition-colors hover:bg-muted/50"
  def ui_table_cell = "p-2 align-middle"
end
