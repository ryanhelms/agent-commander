# Agent Commander component inventory

This audit covers the SwiftUI and AppKit source used to capture the 28 views on November 22, 2026. It counts each named view, style, modifier, layout, toolbar, or app root once. Repeated view instances, enum variants, native SwiftUI controls, and private view-building expressions are described with their owning components. The supporting contracts are listed separately. [Native review gallery](index.html) · [Original concepts](../../concepts/index.html)

## How the layers fit together

| Layer | Named Swift declarations | Role |
| --- | ---: | --- |
| Foundations | 3 | Adaptive ink styles. Other foundation tokens are listed below. |
| Atoms | 16 | Surface, focus, identity, text, and control primitives. |
| Molecules | 45 | Reusable fields, labels, identity, reply, navigation, and form pieces. |
| Organisms | 27 | Feature units that combine several smaller components. |
| Templates | 7 | Reusable window, split, page, collection, row, and sheet arrangements. |
| Pages and page composition | 20 | Workflow screens and shared hosts of those screens. |
| App and preview scaffolding | 5 | Window entry point and review-only rendering tools. |
| **Total** | **123** | Named display declarations in the audited Swift target. |

The live app maps service data through `CockpitModel` and the presentation models into `CockpitScreen`. Preview mode uses `PreviewStore`, `DesignFixture`, and `PreviewSample` to supply the same cockpit shell and screen components. Live actions are callbacks on `CockpitActions`. The preview supplies in-memory callbacks and illustrative states.

`RequestReply` appears in `WorkerTile`, `AttentionStack`, `AttentionDrawer`, and `RequestInspector`. Its draft, send state, focus, and submit callback are keyed by request ID. `InputOwnership` shows who holds terminal input, `TerminalComposer` accepts input when the surface allows it, and `TerminalWell` renders selectable, scrollable output. [Reply and ownership source](../../../Sources/AgentCommander/Molecules.swift) · [Cockpit organisms](../../../Sources/AgentCommander/Organisms.swift) · [Workspace request inspector](../../../Sources/AgentCommander/WorkspaceOrganisms.swift)

## Findings for review

1. **The main composition is in place.** Cockpit and workspace pages use the same `CockpitShell`, `NavigationRail`, and `WorkspaceToolbar`. The cockpit reuses `WorkerTile` for wall and focus; setup and review pages reuse `TaskSheet`, `FormSection`, and `SheetFooter`. Several concepts are different states of one page.
2. **Some visual values still live in their consumers.** `DesignTokens.swift` defines a semantic palette, typography, spacing, radii, and accessibility styles. Several view files still use inline hex colors and local spacing, including workspace table cells and setup status treatments. This makes changes to the shared styles harder to verify centrally.
3. **File boundaries are less strict than the view boundaries.** `Components.swift` holds both the terminal atom and presentation contracts. `DelegationPages.swift` and `SetupPages.swift` contain reusable organisms alongside pages and fixture-friendly models. The inventory classifies declarations by role. Some typography and surface treatments are also spread across `SectionTitle`, `SectionHeading`, `PanelTitle`, `PageHeader`, `FieldBox`, and `TextArea`. Their roles should be checked before consolidating them.
4. **Preview actions vary in depth.** Replies, filters, selections and integration attempt inspection update sample state. Opening another preview resets transient sample state. A few affordances, including preview run stop and the external checkout-link callback, are placeholders. The app currently reports the gallery Next arrow as Previous in some accessibility snapshots, even though its action, help and identifier point forward.
5. **The screenshots are for visual approval.** The native title bar includes gallery controls, some reply fields differ from the concept action rows, and the layout is captured in a slightly shorter window. The reduced-transparency and increased-contrast variants use appearance overrides. The captures show these treatments, and full assistive-technology review requires a separate pass.

## Named components

The implementation type column shows the Swift contract for each component. Source links point to the declaration file and line.

### Foundations

| Component | Implementation type | Responsibility |
| --- | --- | --- |
| [`SecondaryInk`](../../../Sources/AgentCommander/DesignTokens.swift#L140) | `ShapeStyle` | Adapts secondary foreground ink to the increased-contrast preference. |
| [`EdgeInk`](../../../Sources/AgentCommander/DesignTokens.swift#L147) | `ShapeStyle` | Adapts card borders to the increased-contrast preference. |
| [`HairlineInk`](../../../Sources/AgentCommander/DesignTokens.swift#L154) | `ShapeStyle` | Adapts separator ink to the increased-contrast preference. |

### Atoms

| Component | Implementation type | Responsibility |
| --- | --- | --- |
| [`PanelSurface`](../../../Sources/AgentCommander/Atoms.swift#L11) | `ViewModifier` | Shared opaque panel fill, border and radius for cards and inspectors. |
| [`GlassSurface`](../../../Sources/AgentCommander/Atoms.swift#L30) | `ViewModifier` | Liquid Glass treatment for the navigation rail and floating attention, with an opaque fallback. |
| [`FocusRing`](../../../Sources/AgentCommander/Atoms.swift#L59) | `ViewModifier` | Draws the keyboard-target outline for active panes. |
| [`Hairline`](../../../Sources/AgentCommander/Atoms.swift#L91) | `View` | Single horizontal or vertical rule using adaptive separator ink. |
| [`StatusLabel`](../../../Sources/AgentCommander/Atoms.swift#L105) | `View` | State name, dot or symbol and semantic tone for workers, hosts and operations. |
| [`AgentAvatar`](../../../Sources/AgentCommander/Atoms.swift#L151) | `View` | Small client mark for Claude Code, Codex, generic MCP and unknown clients. |
| [`BrandMark`](../../../Sources/AgentCommander/Atoms.swift#L201) | `View` | Commander’s mark in the navigation rail. |
| [`ProjectMark`](../../../Sources/AgentCommander/Atoms.swift#L215) | `View` | Letter mark used to identify a project in navigation. |
| [`KeyCap`](../../../Sources/AgentCommander/Atoms.swift#L233) | `View` | Renders a keyboard key or shortcut in a small rounded keycap. |
| [`CountBadge`](../../../Sources/AgentCommander/Atoms.swift#L248) | `View` | Renders a numeric count, including pending attention in navigation. |
| [`MetaItem`](../../../Sources/AgentCommander/Atoms.swift#L264) | `View` | Icon and text treatment for small metadata items. |
| [`SymbolButton`](../../../Sources/AgentCommander/Atoms.swift#L284) | `View` | Icon-only button with an accessible name and action. |
| [`CapsuleButtonStyle`](../../../Sources/AgentCommander/Atoms.swift#L304) | `ButtonStyle` | Shared neutral or primary button appearance and interaction states. |
| [`HandbackButtonStyle`](../../../Sources/AgentCommander/Atoms.swift#L331) | `ButtonStyle` | Compact treatment for returning a terminal’s input ownership. |
| [`FieldBox`](../../../Sources/AgentCommander/Atoms.swift#L345) | `ViewModifier` | Shared single-line field container and focus treatment. |
| [`TerminalWell`](../../../Sources/AgentCommander/Components.swift#L316) | `NSViewRepresentable` | AppKit-backed selectable terminal output with dense and expanded text styles, scroll preservation and an accessibility label. |

### Molecules

| Component | Implementation type | Responsibility |
| --- | --- | --- |
| [`WorkerIdentity`](../../../Sources/AgentCommander/Molecules.swift#L12) | `View` | Client avatar, agent name and metadata with tile, console, focused and PiP densities. |
| [`WorkerLocation`](../../../Sources/AgentCommander/Molecules.swift#L62) | `View` | Host and checkout or branch identity shown alongside worker context. |
| [`InputOwnership`](../../../Sources/AgentCommander/Molecules.swift#L84) | `View` | Shows who controls a worker and provides a handback action when available. |
| [`RequestReply`](../../../Sources/AgentCommander/Molecules.swift#L163) | `View` | Binds a reply field and send action to a request ID. The focused field owns the keyboard shortcut. |
| [`AssignmentBlock`](../../../Sources/AgentCommander/Molecules.swift#L214) | `View` | Label, optional timestamp and formatted assignment text above a conversation. |
| [`TerminalComposer`](../../../Sources/AgentCommander/Molecules.swift#L246) | `View` | Input field and send action for authorized terminal or coordinator messaging surfaces. |
| [`NeedsInputFlag`](../../../Sources/AgentCommander/Molecules.swift#L295) | `View` | Small request-aware indicator in a worker footer. |
| [`AttentionNotice`](../../../Sources/AgentCommander/Molecules.swift#L311) | `View` | Clickable coordinator-context notice for the worker waiting on a decision. |
| [`Breadcrumb`](../../../Sources/AgentCommander/Molecules.swift#L342) | `View` | Toolbar path with separators for workspace, project, run and worker. |
| [`LineagePath`](../../../Sources/AgentCommander/Molecules.swift#L362) | `View` | Shows the coordinator and parent chain attached to a worker or request. |
| [`SectionTitle`](../../../Sources/AgentCommander/Molecules.swift#L381) | `View` | Compact cockpit section title with an optional count. |
| [`SectionBar`](../../../Sources/AgentCommander/Molecules.swift#L398) | `View` | Positions leading and trailing controls in a cockpit section header. |
| [`KeyHint`](../../../Sources/AgentCommander/Molecules.swift#L413) | `View` | Pairs shortcut keycaps and text with an optional action. |
| [`ConnectionIndicator`](../../../Sources/AgentCommander/Molecules.swift#L434) | `View` | Local service state in the workspace toolbar. |
| [`NoticeBanner`](../../../Sources/AgentCommander/Molecules.swift#L468) | `View` | Shows a connection or service message with a relevant action. |
| [`NavigationRow`](../../../Sources/AgentCommander/Molecules.swift#L503) | `View` | Selectable icon or project navigation item, with a count when present. |
| [`LabeledField`](../../../Sources/AgentCommander/Molecules.swift#L564) | `View` | Pairs a form label with supplied field content. |
| [`StaticField`](../../../Sources/AgentCommander/Molecules.swift#L578) | `View` | Read-only value in the shared field treatment, with optional icon and visual affordance. |
| [`CapabilityChip`](../../../Sources/AgentCommander/Molecules.swift#L599) | `View` | Small client, policy or feature tag. |
| [`ChoiceRow`](../../../Sources/AgentCommander/Molecules.swift#L616) | `View` | Selectable option with a caption and supporting description. |
| [`HostAvailabilityRow`](../../../Sources/AgentCommander/Molecules.swift#L653) | `View` | Summarizes a host’s purpose and availability in the run preview. |
| [`KeyValueRow`](../../../Sources/AgentCommander/Molecules.swift#L676) | `View` | Aligns one label and value inside an inspector or summary. |
| [`Kicker`](../../../Sources/AgentCommander/Molecules.swift#L696) | `View` | Small section-label typography for forms, inspectors and pages. |
| [`PageHeader`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L10) | `View` | Workspace page title, description and trailing actions. |
| [`SectionHeading`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L34) | `View` | Workspace section title and optional trailing status or controls. |
| [`MetaText`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L49) | `View` | Secondary text for counts, hints and compact facts. |
| [`IconTile`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L63) | `View` | Reusable icon inside a small colored or outlined tile. |
| [`ValueTag`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L81) | `View` | Compact value such as a branch, revision or rule. |
| [`FilterChip`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L102) | `View` | Labeled menu that binds a selected filter value. |
| [`SelectionCard`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L131) | `ViewModifier` | Styling modifier for selectable cards and selected rows. |
| [`CheckToggle`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L158) | `View` | Checkbox treatment for host, launch and review choices. |
| [`SearchField`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L182) | `View` | Labeled search input for workspace history. |
| [`Callout`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L206) | `View` | Icon, title and supporting message with semantic tone. |
| [`EvidenceRow`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L233) | `View` | A label and evidence detail for capability checks and review state. |
| [`SettingRow`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L257) | `View` | Aligns a setting’s label and explanation with its input. |
| [`FactColumn`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L276) | `View` | Stacked fact label and value for detail panels. |
| [`PanelTitle`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L295) | `View` | Inspector heading treatment with an optional symbol. |
| [`ConsolePreview`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L315) | `View` | Compact terminal snippet from typed, styled display lines on workspace overview cards. |
| [`MenuField`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L361) | `View` | Field-shaped selector with a binding and visual selection affordance. |
| [`FormSection`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L391) | `View` | Section heading and content for a task or review form. |
| [`SheetFooter`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L406) | `View` | Places status or notes and task actions in a consistent footer. |
| [`InspectorCard`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L421) | `ViewModifier` | Shared surface modifier for a task’s right-side inspector. |
| [`TextArea`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L435) | `View` | Multi-line form editor with a visible focus treatment and accessible label. |
| [`UnavailableAction`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L457) | `View` | Disabled action with a reason available through help and accessibility. |
| [`HighlightedText`](../../../Sources/AgentCommander/WorkspaceMolecules.swift#L473) | `View` | Highlights every matching term in history snippets and transcript lines. |

### Organisms

| Component | Implementation type | Responsibility |
| --- | --- | --- |
| [`WorkspaceToolbar`](../../../Sources/AgentCommander/CockpitView.swift#L59) | `ToolbarContent` | Composes sidebar toggle, breadcrumbs, optional workspace search, preview accessory and service connection status. |
| [`WorkerTile`](../../../Sources/AgentCommander/Organisms.swift#L36) | `View` | Builds a wall card or focused console from identity, assignment, location, output, request and ownership. |
| [`WorkerActionMenu`](../../../Sources/AgentCommander/Organisms.swift#L297) | `View` | Shows operations scoped to the selected tile such as zoom, follow-up, take control and stop. |
| [`NestedWorkerGroup`](../../../Sources/AgentCommander/Organisms.swift#L369) | `View` | Expandable parent-scoped group for workers delegated by another worker. |
| [`WorkerWall`](../../../Sources/AgentCommander/Organisms.swift#L414) | `View` | Lays out worker tiles and nested groups in adaptive rows. |
| [`CoordinatorConsole`](../../../Sources/AgentCommander/Organisms.swift#L520) | `View` | Combines the coordinator identity, assignment, transcript, attention notices and available input. |
| [`AttentionStack`](../../../Sources/AgentCommander/Organisms.swift#L604) | `View` | Stacks pending requests in PiP with requester identity, context and the scoped reply field. |
| [`AttentionDrawer`](../../../Sources/AgentCommander/Organisms.swift#L716) | `View` | Shows a selected pending request in a side panel without replacing the wall. |
| [`ReturnStrip`](../../../Sources/AgentCommander/Organisms.swift#L830) | `View` | Identifies the interruption and offers a return to the previous run and worker. |
| [`RunHeader`](../../../Sources/AgentCommander/Organisms.swift#L860) | `View` | Shows the current run, status, worker counts and run actions above the cockpit. |
| [`RunDetails`](../../../Sources/AgentCommander/Organisms.swift#L925) | `View` | Displays run metadata in the run-details popover. |
| [`NavigationRail`](../../../Sources/AgentCommander/Organisms.swift#L961) | `View` | Composes workspace, project and saved-view navigation with shared glass and row styling. |
| [`RunChooser`](../../../Sources/AgentCommander/Organisms.swift#L1015) | `View` | Lists projects and runs for switching the active cockpit. |
| [`DataTable`](../../../Sources/AgentCommander/WorkspaceOrganisms.swift#L18) | `View` | Reusable header and row structure backed by weighted columns and a caller-supplied cell renderer. |
| [`AgentConsoleCard`](../../../Sources/AgentCommander/WorkspaceOrganisms.swift#L77) | `View` | Compact worker or coordinator summary with a semantic status and selectable console preview. |
| [`CoordinatorSummary`](../../../Sources/AgentCommander/WorkspaceOrganisms.swift#L119) | `View` | Run overview card with key facts and selectable worker hierarchy. |
| [`CoordinatorRow`](../../../Sources/AgentCommander/WorkspaceOrganisms.swift#L192) | `View` | Compact coordinator summary for secondary runs in a project. |
| [`RequestList`](../../../Sources/AgentCommander/WorkspaceOrganisms.swift#L232) | `View` | Pending requests and recently resolved entries with per-request selection. |
| [`RequestInspector`](../../../Sources/AgentCommander/WorkspaceOrganisms.swift#L291) | `View` | Requester, lineage, transcript context and the same scoped reply field used in the cockpit. |
| [`RuleInspector`](../../../Sources/AgentCommander/WorkspaceOrganisms.swift#L389) | `View` | Shows saved smart-view matching rules and their filter values. |
| [`CheckoutComparison`](../../../Sources/AgentCommander/WorkspaceOrganisms.swift#L431) | `View` | Shows checkout identity evidence and link or keep-separate decisions. |
| [`VerificationLog`](../../../Sources/AgentCommander/DelegationPages.swift#L23) | `View` | Structured combined-test output for integration attempts. |
| [`AttemptHistory`](../../../Sources/AgentCommander/DelegationPages.swift#L94) | `View` | Selectable integration attempts with outcome labels and timestamps. |
| [`TranscriptInspector`](../../../Sources/AgentCommander/DelegationPages.swift#L155) | `View` | Selected run and worker provenance, matching text, and surrounding transcript. |
| [`PresentationThumbnail`](../../../Sources/AgentCommander/SetupPages.swift#L20) | `View` | Drawn schematic of one attention presentation. |
| [`PresentationChoiceCard`](../../../Sources/AgentCommander/SetupPages.swift#L83) | `View` | Selectable attention option combining a schematic, label and its expected behavior. |
| [`ConnectionTimeline`](../../../Sources/AgentCommander/SetupPages.swift#L131) | `View` | Ordered connection and recovery events with status cues. |

### Templates

| Component | Implementation type | Responsibility |
| --- | --- | --- |
| [`CockpitShell`](../../../Sources/AgentCommander/Templates.swift#L17) | `View` | Shared window composition with regions for navigation, banners and page content. |
| [`WindowGlass`](../../../Sources/AgentCommander/Templates.swift#L69) | `ViewModifier` | Window background, depth and border treatment shared through the shell. |
| [`CoordinatorSplit`](../../../Sources/AgentCommander/Templates.swift#L85) | `View` | Resizable coordinator and worker columns with header and floating content slots. |
| [`WorkspacePage`](../../../Sources/AgentCommander/Templates.swift#L176) | `View` | Workspace header and scrolling main content region. |
| [`CollectionInspector`](../../../Sources/AgentCommander/Templates.swift#L198) | `View` | Collection and detail regions that adapt to available width. |
| [`WeightedRow`](../../../Sources/AgentCommander/Templates.swift#L223) | `Layout` | SwiftUI layout primitive for aligned table columns with relative weights. |
| [`TaskSheet`](../../../Sources/AgentCommander/Templates.swift#L263) | `View` | Task header, form, optional inspector and persistent action footer. |

### Pages and page composition

| Component | Implementation type | Responsibility |
| --- | --- | --- |
| [`CockpitScreen`](../../../Sources/AgentCommander/CockpitView.swift#L110) | `View` | Composes shared run navigation, wall, focus, attention and new-run layouts from values and action callbacks. |
| [`CockpitView`](../../../Sources/AgentCommander/CockpitView.swift#L669) | `View` | Adapts the live feature model to CockpitScreen and starts the service subscription. |
| [`WorkspaceScreen`](../../../Sources/AgentCommander/WorkspaceScreen.swift#L7) | `View` | Hosts workspace pages in the same shell, toolbar and navigation rail as the cockpit. |
| [`NewRunView`](../../../Sources/AgentCommander/RunViews.swift#L68) | `View` | Run setup with a title, checkout and task, plus capability-driven preview policies. |
| [`AttentionQueuePage`](../../../Sources/AgentCommander/WorkspacePages.swift#L15) | `View` | Workspace-wide pending and resolved requests, selected request inspection and presentation choices. |
| [`AllAgentsPage`](../../../Sources/AgentCommander/WorkspacePages.swift#L158) | `View` | Cross-project grid or list with project, host, state, run, client and role filters. |
| [`ProjectPage`](../../../Sources/AgentCommander/WorkspacePages.swift#L350) | `View` | Coordinator tree, linked checkouts and launch entry points for a project. |
| [`SmartViewPage`](../../../Sources/AgentCommander/WorkspacePages.swift#L417) | `View` | Matching agents, sample console previews and the saved query rules. |
| [`LinkCheckoutPage`](../../../Sources/AgentCommander/WorkspacePages.swift#L530) | `View` | Review of ambiguous repository identity and checkout linking choices. |
| [`DelegateWorkerPage`](../../../Sources/AgentCommander/DelegationPages.swift#L273) | `View` | Assignment, launch choices and inherited changes or starting workspace. |
| [`IntegrationPage`](../../../Sources/AgentCommander/DelegationPages.swift#L475) | `View` | Selected handoffs, combined verification, attempts and action affordances for successful or blocked integration. |
| [`HistoryPage`](../../../Sources/AgentCommander/DelegationPages.swift#L650) | `View` | Filter and search transcript matches and inspect related terminal context. |
| [`CrossRunPage`](../../../Sources/AgentCommander/DelegationPages.swift#L798) | `View` | Peer transcript, question to the run owner and restrictions on controlling another run. |
| [`FirstRunPage`](../../../Sources/AgentCommander/SetupPages.swift#L179) | `View` | Project discovery, selectable hosts and sessions, and progress through initial setup. |
| [`HostsPage`](../../../Sources/AgentCommander/SetupPages.swift#L396) | `View` | Host selection, connection capabilities, policy and recovery entry points. |
| [`ClientsPage`](../../../Sources/AgentCommander/SetupPages.swift#L612) | `View` | Client selection, launch profile, MCP configuration and capability displays. |
| [`AdoptionPage`](../../../Sources/AgentCommander/SetupPages.swift#L801) | `View` | Discovered sessions, identity evidence and available adoption paths. |
| [`RecoveryPage`](../../../Sources/AgentCommander/SetupPages.swift#L1040) | `View` | Connection events, affected workers, input ownership and delivery evidence. |
| [`OperationDetailPage`](../../../Sources/AgentCommander/SetupPages.swift#L1205) | `View` | Provider sign-in continuation, operation metadata and history. |
| [`PreferencesPage`](../../../Sources/AgentCommander/SetupPages.swift#L1318) | `View` | Attention presentation, recording and retention settings and appearance status. |

### App and preview scaffolding

| Component | Implementation type | Responsibility |
| --- | --- | --- |
| [`AgentCommander`](../../../Sources/AgentCommander/AgentCommander.swift#L5) | `App` | Native window entry point that selects the live cockpit or a design preview. |
| [`DesignPreviewPage`](../../../Sources/AgentCommander/DesignPreview.swift#L337) | `View` | Puts fixture state into CockpitScreen or WorkspaceScreen and applies preview appearance. |
| [`PreviewCanvas`](../../../Sources/AgentCommander/DesignPreview.swift#L427) | `View` | Routes workspace scenario IDs to the native pages and injects their sample data. |
| [`PreviewGalleryControl`](../../../Sources/AgentCommander/DesignPreview.swift#L379) | `View` | Preview-only view chooser, navigation arrows, sample activity toggle and reset. |
| [`PreviewWindowFrame`](../../../Sources/AgentCommander/DesignPreview.swift#L524) | `NSViewRepresentable` | AppKit probe that requests a repeatable window frame for review. |

## Supporting contracts and state

| Source | Types and extensions | Purpose |
| --- | --- | --- |
| [DesignTokens.swift](../../../Sources/AgentCommander/DesignTokens.swift) | `Palette`, `Space`, `Radius`, `Metric`, `TypeRole`, `Color.init(hex:opacity:)`, `ReduceTransparencyOverrideKey`, `IncreaseContrastOverrideKey`, `EnvironmentValues` and `ShapeStyle` extensions | Semantic colors, sizing, typography and adaptive appearance. |
| [Atoms.swift](../../../Sources/AgentCommander/Atoms.swift) and [WorkspaceMolecules.swift](../../../Sources/AgentCommander/WorkspaceMolecules.swift) | `panelSurface`, `glassSurface`, `focusRing`, `fieldBox`, `selectionCard`, `inspectorCard` and `ConsolePreview.Line` | Style entry points and a typed terminal-snippet line. |
| [Components.swift](../../../Sources/AgentCommander/Components.swift) | `Tone`, `AgentClient`, `TaskState`, `InputControl`, `RequestPresentation`, `WorkerPresentation`, `WorkerGroup`, `WallLayout`, `RunSummary`, `RunContent`, `CockpitContent`, `CockpitActions`, `AttentionPresentation`, `ReturnTarget`, `Identifier`, `Timestamp`, `PathDisplay`, `NSColor` helper and model-mapping extensions | Presentation values, callbacks, and conversion from service models to the shared cockpit. `TerminalWell.Style` and `TerminalWell.Coordinator` implement text display and AppKit coordination. |
| [Molecules.swift](../../../Sources/AgentCommander/Molecules.swift) and [Organisms.swift](../../../Sources/AgentCommander/Organisms.swift) | `WorkerIdentity.Density`, `WorkerIdentity.Detail`, `ReplyContext`, `NavigationItem` and `Mark`, `NavigationGroup`, `WorkerTileActions`, `WorkerTile.Variant`, `WorkerWall.Row` and its array layout helper | Identity density, request-scoped input, view actions and grouping records. |
| [CockpitView.swift](../../../Sources/AgentCommander/CockpitView.swift) | `CockpitPresentationState`, `FixtureNavigation` | Holds selection, focus, drafts, and local cockpit display state. Supplies preview navigation separately from the live destination list. |
| [WorkspaceOrganisms.swift](../../../Sources/AgentCommander/WorkspaceOrganisms.swift) and [WorkspacePages.swift](../../../Sources/AgentCommander/WorkspacePages.swift) | `AgentConsole`, `CoordinatorSummary.Node`, `ResolvedRequest`, `ViewRule`, `IdentityCheck`, `CheckoutComparison.Decision`, `CheckoutLink` | Workspace lists, request displays, saved filters, and repository identity evidence. |
| [RunViews.swift](../../../Sources/AgentCommander/RunViews.swift) and [DelegationPages.swift](../../../Sources/AgentCommander/DelegationPages.swift) | `NewRunDraft`, `RunSetupCapabilities` and nested records, `NewRunView.Field`, `LogLine`, `IntegrationAttempt` and `Outcome`, `TranscriptLine`, `TranscriptMatch`, `WorkingChange`, `DelegationSetup`, `DelegateWorkerPage.Workspace`, `Handoff`, `IntegrationReview`, `SharedEntry`, `CrossRunAccess` | Inputs and display values for run setup, worker launch, candidate review, transcript search and peer coordination. |
| [SetupPages.swift](../../../Sources/AgentCommander/SetupPages.swift) | `TimelineEvent`, `SetupHost`, `DiscoveredSession`, `EnrolledHost`, `CapabilityComparison`, `ClientCapability`, `ClientProfile`, `PreservationCheck`, `DiscoveredPane` and `Identity`, `AffectedWorker` and `Follow`, `RecoveryReport`, `RecoveryPage.Delivery`, `OperationFact`, `OperationEvent`, `OperationDetail`, `OperationDetailPage.Phase` | View inputs and local transitions for enrollment, adoption, recovery and provider operations. |
| [DesignPreview.swift](../../../Sources/AgentCommander/DesignPreview.swift) and [PreviewSamples.swift](../../../Sources/AgentCommander/PreviewSamples.swift) | `DesignPreviewScenario` and `Info`, `PreviewStore`, `DesignFixture`, `PreviewSample`, `PreviewWindowFrame.Probe` | Catalog and sample workspace data, scenario routing, transient interactions, deterministic defaults and window setup. |
| [CockpitModel.swift](../../../Sources/AgentCommander/CockpitModel.swift) and [ServiceClient.swift](../../../Sources/AgentCommander/ServiceClient.swift) | `CockpitModel`, `ServiceClient`, `Worker`, `Question`, `Run`, `RunList`, `PendingDecision`, `ServiceError` | Live feature model, API client and service data contracts. |

## All 28 views and their primary composition

| # | View | Primary page and major composition |
| ---: | --- | --- |
| 1 | [Coordinator wall](index.html#coordinator-wall) | `CockpitScreen` → `CoordinatorSplit`, `CoordinatorConsole`, `WorkerWall`, `NestedWorkerGroup`, `WorkerTile` |
| 2 | [Focused worker](index.html#focused-worker) | `CockpitScreen` → focused `WorkerTile`, `AssignmentBlock`, `TerminalWell`, `InputOwnership`, `RequestReply` |
| 3 | [Worker actions](index.html#tile-controls) | `CockpitScreen` → `WorkerTile`, `WorkerActionMenu` |
| 4 | [Picture-in-picture reply](index.html#attention-pip) | `CockpitScreen` → `AttentionStack`, `WorkerIdentity`, `RequestReply` |
| 5 | [An incoming request](index.html#pip-arrival) | `CockpitScreen` → `WorkerTile`, `InputOwnership`, `AttentionStack` |
| 6 | [Attention queue](index.html#attention-queue) | `AttentionQueuePage` → `RequestList`, `RequestInspector`, `RequestReply` |
| 7 | [Attention side panel](index.html#attention-panel) | `CockpitScreen` → `WorkerWall`, `AttentionDrawer`, `RequestReply` |
| 8 | [Switch to a blocked run](index.html#attention-switch) | `CockpitScreen` → `ReturnStrip`, focused `WorkerTile` |
| 9 | [All agents](index.html#all-agents) | `AllAgentsPage` → `WorkspacePage`, `FilterChip`, `AgentConsoleCard`, `DataTable` |
| 10 | [Project overview](index.html#project) | `ProjectPage` → `CoordinatorSummary`, `CoordinatorRow`, `DataTable` |
| 11 | [Saved smart view](index.html#smart-view) | `SmartViewPage` → `CollectionInspector`, `RuleInspector`, `AgentConsoleCard`, `DataTable` |
| 12 | [Link a checkout](index.html#link-checkout) | `LinkCheckoutPage` → `CheckoutComparison`, `DataTable`, `Callout` |
| 13 | [Start a coordinator](index.html#start-run) | `CockpitScreen` → `NewRunView`, `TaskSheet`, capability and host fields |
| 14 | [Delegate a worker](index.html#delegate-worker) | `DelegateWorkerPage` → `TaskSheet`, `FormSection`, `MenuField`, `ChoiceRow` |
| 15 | [Integrate worker changes](index.html#integration) | `IntegrationPage` → `TaskSheet`, `DataTable`, `VerificationLog`, `AttemptHistory` |
| 16 | [A blocked integration](index.html#integration-blocked) | `IntegrationPage` with failed attempt → `VerificationLog`, `AttemptHistory`, `UnavailableAction` |
| 17 | [Search run history](index.html#history) | `HistoryPage` → `SearchField`, `FilterChip`, `TranscriptInspector`, `HighlightedText` |
| 18 | [Cross-run access](index.html#cross-run) | `CrossRunPage` → `TaskSheet`, `FormSection`, `Callout`, `UnavailableAction` |
| 19 | [Connect a workspace](index.html#first-run) | `FirstRunPage` → `WorkspacePage`, `CheckToggle`, `StatusLabel` |
| 20 | [Hosts and capabilities](index.html#hosts) | `HostsPage` → `CollectionInspector`, `DataTable`, `FactColumn` |
| 21 | [Clients and MCP](index.html#clients) | `ClientsPage` → `WorkspacePage`, `SelectionCard`, `EvidenceRow`, `LabeledField` |
| 22 | [Adopt an existing session](index.html#adoption) | `AdoptionPage` → `CollectionInspector`, `EvidenceRow`, `UnavailableAction` |
| 23 | [Recover a connection](index.html#recovery) | `RecoveryPage` → `TaskSheet`, `ConnectionTimeline`, `DataTable`, `Callout` |
| 24 | [Provider sign-in](index.html#operation-detail) | `OperationDetailPage` → `WorkspacePage`, `DataTable`, `Callout` |
| 25 | [Workspace preferences](index.html#preferences) | `PreferencesPage` → `PresentationChoiceCard`, `PresentationThumbnail`, `SettingRow` |
| 26 | [Reduced transparency](index.html#reduced-transparency) | `PreferencesPage` with appearance overrides → `PresentationChoiceCard`, `SettingRow` |
| 27 | [Reduced transparency · PiP](index.html#accessible-wall) | `CockpitScreen` with appearance overrides → `WorkerWall`, `AttentionStack` |
| 28 | [Reduced transparency · worker](index.html#accessible-worker) | `CockpitScreen` with appearance overrides → focused `WorkerTile`, `RequestReply`, `InputOwnership` |
