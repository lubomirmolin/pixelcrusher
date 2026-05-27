import {
  Activity,
  ChevronDown,
  ChevronUp,
  Crop,
  FileArchive,
  Maximize2,
  Plus,
  RefreshCw,
  WandSparkles,
  X,
} from 'lucide-react';
import {
  AUTOMATION_ACTION_META,
  BACKGROUND_MODEL_LABELS,
  OUTPUT_FORMAT_LABELS,
} from '../features/app/constants';
import type {
  AutomationActionKind,
  BackgroundRemovalModelVariant,
  OutputImageFormat,
} from '../features/app/types';

type AutomationSidebarProps = {
  actions: AutomationActionKind[];
  availableActions: AutomationActionKind[];
  autoTrimTransparentBorders: boolean;
  setAutoTrimTransparentBorders: (next: boolean) => void;
  autoResizeLongestSideEnabled: boolean;
  setAutoResizeLongestSideEnabled: (next: boolean) => void;
  autoResizeLongestSide: string;
  setAutoResizeLongestSide: (next: string) => void;
  autoConvertOutputFormat: OutputImageFormat | null;
  setAutoConvertOutputFormat: (next: OutputImageFormat | null) => void;
  selectedBackgroundRemovalModel: BackgroundRemovalModelVariant;
  setSelectedBackgroundRemovalModel: (next: BackgroundRemovalModelVariant) => void;
  addAutomationAction: (action: AutomationActionKind) => void;
  removeAutomationAction: (action: AutomationActionKind) => void;
  moveAutomationAction: (action: AutomationActionKind, direction: -1 | 1) => void;
};

const ACTION_ICONS: Record<AutomationActionKind, typeof Activity> = {
  compression: FileArchive,
  removeBackground: WandSparkles,
  resize: Maximize2,
  convertFormat: RefreshCw,
  trimTransparentBorders: Crop,
};

const outputOptions: Array<{ value: OutputImageFormat | ''; label: string }> = [
  { value: '', label: 'Keep original' },
  { value: 'png', label: OUTPUT_FORMAT_LABELS.png },
  { value: 'jpeg', label: OUTPUT_FORMAT_LABELS.jpeg },
  { value: 'gif', label: OUTPUT_FORMAT_LABELS.gif },
  { value: 'webp', label: OUTPUT_FORMAT_LABELS.webp },
];

export function AutomationSidebar({
  actions,
  availableActions,
  autoTrimTransparentBorders,
  setAutoTrimTransparentBorders,
  autoResizeLongestSideEnabled,
  setAutoResizeLongestSideEnabled,
  autoResizeLongestSide,
  setAutoResizeLongestSide,
  autoConvertOutputFormat,
  setAutoConvertOutputFormat,
  selectedBackgroundRemovalModel,
  setSelectedBackgroundRemovalModel,
  addAutomationAction,
  removeAutomationAction,
  moveAutomationAction,
}: AutomationSidebarProps) {
  const canAdd = availableActions.length > 0;

  return (
    <aside className="w-[320px] min-w-[280px] max-w-[380px] border-r border-black/10 bg-[#f2f3f5]/95 flex flex-col">
      <div className="px-[18px] py-[18px] flex items-center gap-3">
        <Activity size={24} className="text-[#005fb8]" />
        <h2 className="text-[20px] font-semibold text-gray-900">Automations</h2>
      </div>
      <div className="h-px bg-black/10" />

      <div className="flex-1 overflow-y-auto p-[18px] space-y-3">
        <p className="text-[13px] leading-5 font-medium text-gray-500">
          Build a chain of actions. Dropped images run through these steps and save one final output.
        </p>

        <div className="space-y-2.5">
          {actions.map((action, index) => (
          <AutomationActionCard
              key={action}
              action={action}
              index={index}
              total={actions.length}
              autoTrimTransparentBorders={autoTrimTransparentBorders}
              setAutoTrimTransparentBorders={setAutoTrimTransparentBorders}
              autoResizeLongestSideEnabled={autoResizeLongestSideEnabled}
              setAutoResizeLongestSideEnabled={setAutoResizeLongestSideEnabled}
              autoResizeLongestSide={autoResizeLongestSide}
              setAutoResizeLongestSide={setAutoResizeLongestSide}
              autoConvertOutputFormat={autoConvertOutputFormat}
              setAutoConvertOutputFormat={setAutoConvertOutputFormat}
              selectedBackgroundRemovalModel={selectedBackgroundRemovalModel}
              setSelectedBackgroundRemovalModel={setSelectedBackgroundRemovalModel}
              removeAutomationAction={removeAutomationAction}
              moveAutomationAction={moveAutomationAction}
            />
          ))}
        </div>

        <div className="pt-1">
          <label className="sr-only" htmlFor="add-action-select">Add automation action</label>
          <div className="relative">
            <select
              id="add-action-select"
              disabled={!canAdd}
              value=""
              onChange={(event) => {
                const action = event.target.value as AutomationActionKind;
                if (action) {
                  addAutomationAction(action);
                }
              }}
              className="w-full appearance-none rounded-md border border-gray-300 bg-white py-2.5 pl-10 pr-8 text-[14px] font-semibold text-gray-800 shadow-sm disabled:opacity-50"
            >
              <option value="">{canAdd ? 'Add Action' : 'All actions added'}</option>
              {availableActions.map((action) => (
                <option key={action} value={action}>
                  {AUTOMATION_ACTION_META[action].title}
                </option>
              ))}
            </select>
            <Plus size={16} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-gray-500" />
          </div>
        </div>
      </div>
    </aside>
  );
}

type AutomationActionCardProps = Omit<AutomationSidebarProps, 'actions' | 'availableActions' | 'addAutomationAction'> & {
  action: AutomationActionKind;
  index: number;
  total: number;
};

function AutomationActionCard({
  action,
  index,
  total,
  autoTrimTransparentBorders,
  setAutoTrimTransparentBorders,
  autoResizeLongestSideEnabled,
  setAutoResizeLongestSideEnabled,
  autoResizeLongestSide,
  setAutoResizeLongestSide,
  autoConvertOutputFormat,
  setAutoConvertOutputFormat,
  selectedBackgroundRemovalModel,
  setSelectedBackgroundRemovalModel,
  removeAutomationAction,
  moveAutomationAction,
}: AutomationActionCardProps) {
  const Icon = ACTION_ICONS[action];
  const meta = AUTOMATION_ACTION_META[action];

  return (
    <section className="rounded-lg border border-black/10 bg-white/90 p-3 shadow-sm">
      <div className="flex items-start gap-3">
        <div className="grid h-[34px] w-[34px] place-items-center rounded-[7px] border border-black/10 bg-gray-50 text-gray-600">
          <Icon size={17} className={action === 'compression' ? 'text-[#005fb8]' : undefined} />
        </div>

        <div className="min-w-0 flex-1">
          <h3 className="truncate text-[15px] font-semibold text-gray-900">{meta.title}</h3>
          <p className="text-[12px] font-medium text-gray-500">{meta.subtitle}</p>
        </div>

        <div className="flex items-center gap-0.5">
          <button
            type="button"
            onClick={() => moveAutomationAction(action, -1)}
            disabled={index === 0}
            title="Move up"
            className="grid h-7 w-7 place-items-center rounded text-gray-500 hover:bg-black/5 disabled:opacity-35"
          >
            <ChevronUp size={14} />
          </button>
          <button
            type="button"
            onClick={() => moveAutomationAction(action, 1)}
            disabled={index === total - 1}
            title="Move down"
            className="grid h-7 w-7 place-items-center rounded text-gray-500 hover:bg-black/5 disabled:opacity-35"
          >
            <ChevronDown size={14} />
          </button>
          {action !== 'compression' ? (
            <button
              type="button"
              onClick={() => removeAutomationAction(action)}
              title="Remove action"
              className="grid h-7 w-7 place-items-center rounded text-gray-500 hover:bg-black/5"
            >
              <X size={14} />
            </button>
          ) : null}
        </div>
      </div>

      <div className="mt-3">
        {action === 'removeBackground' ? (
          <label className="grid gap-1 text-[12px] font-medium text-gray-600">
            Model
            <select
              value={selectedBackgroundRemovalModel}
              onChange={(event) => setSelectedBackgroundRemovalModel(event.target.value as BackgroundRemovalModelVariant)}
              className="rounded-md border border-gray-300 bg-white px-2 py-1.5 text-[13px] text-gray-900"
            >
              <option value="fast">{BACKGROUND_MODEL_LABELS.fast}</option>
              <option value="highQuality">{BACKGROUND_MODEL_LABELS.highQuality}</option>
            </select>
          </label>
        ) : null}

        {action === 'resize' ? (
          <div className="space-y-2">
            <label className="flex items-center gap-2 text-[13px] font-medium text-gray-700">
              <input
                type="checkbox"
                checked={autoResizeLongestSideEnabled}
                onChange={(event) => setAutoResizeLongestSideEnabled(event.target.checked)}
                className="h-4 w-4"
              />
              Resize by max side
            </label>
            <label className="flex items-center gap-2 text-[12px] font-medium text-gray-600">
              Max side
              <input
                type="number"
                min={1}
                value={autoResizeLongestSide}
                onChange={(event) => setAutoResizeLongestSide(event.target.value)}
                disabled={!autoResizeLongestSideEnabled}
                className="w-[82px] rounded-md border border-gray-300 bg-white px-2 py-1 text-[13px] text-gray-900 disabled:opacity-50"
              />
              px
            </label>
          </div>
        ) : null}

        {action === 'convertFormat' ? (
          <label className="grid gap-1 text-[12px] font-medium text-gray-600">
            Format
            <select
              value={autoConvertOutputFormat ?? ''}
              onChange={(event) => {
                const value = event.target.value;
                setAutoConvertOutputFormat(value ? (value as OutputImageFormat) : null);
              }}
              className="rounded-md border border-gray-300 bg-white px-2 py-1.5 text-[13px] text-gray-900"
            >
              {outputOptions.map((option) => (
                <option key={option.value || 'original'} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
        ) : null}

        {action === 'trimTransparentBorders' ? (
          <label className="flex items-center gap-2 text-[13px] font-medium text-gray-700">
            <input
              type="checkbox"
              checked={autoTrimTransparentBorders}
              onChange={(event) => setAutoTrimTransparentBorders(event.target.checked)}
              className="h-4 w-4"
            />
            Trim transparent borders
          </label>
        ) : null}
      </div>
    </section>
  );
}
