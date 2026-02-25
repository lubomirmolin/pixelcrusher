import { Crop, X } from 'lucide-react';
import type { JobResultEntry } from '../state/queueState';
import type { CropDraft } from '../features/app/types';
import { toAssetUrl } from '../features/app/utils';

type CropModalProps = {
  activeItem: JobResultEntry | null;
  draft: CropDraft;
  onDraftChange: (next: CropDraft) => void;
  onClose: () => void;
  onApply: () => void;
};

export function CropModal({ activeItem, draft, onDraftChange, onClose, onApply }: CropModalProps) {
  if (!activeItem) {
    return null;
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm">
      <div className="w-[400px] shadow-2xl overflow-hidden flex flex-col transform transition-all rounded-lg bg-white border border-gray-300">
        <div className="h-12 flex items-center justify-between px-6 relative">
          <span className="font-semibold text-gray-900 text-[15px]">Crop Image</span>
          <button onClick={onClose} className="text-gray-500 hover:text-[#e81123] hover:bg-black/5 p-1 rounded transition-colors">
            <X size={16} />
          </button>
        </div>
        <div className="p-6 flex-1 bg-white">
          <div className="space-y-4">
            <div className="w-full h-48 overflow-hidden relative bg-[#f3f3f3] rounded-md border border-gray-200">
              <img src={toAssetUrl(activeItem.input_path)} className="w-full h-full object-contain opacity-50" alt="" />
              <div className="absolute inset-8 border-2 border-white shadow-[0_0_0_999px_rgba(0,0,0,0.4)] flex items-center justify-center">
                <Crop size={24} className="text-white opacity-80" />
              </div>
            </div>
            <div className="flex items-center space-x-4">
              <div className="flex-1">
                <label className="block text-[11px] font-medium mb-1 text-gray-800">Width</label>
                <input
                  type="number"
                  value={draft.width}
                  onChange={(event) => onDraftChange({ ...draft, width: event.target.value })}
                  className="w-full text-[13px] px-2 py-1.5 focus:outline-none bg-white border-b-2 border-gray-300 rounded text-gray-900 focus:border-[#005fb8]"
                />
              </div>
              <div className="flex-1">
                <label className="block text-[11px] font-medium mb-1 text-gray-800">Height</label>
                <input
                  type="number"
                  value={draft.height}
                  onChange={(event) => onDraftChange({ ...draft, height: event.target.value })}
                  className="w-full text-[13px] px-2 py-1.5 focus:outline-none bg-white border-b-2 border-gray-300 rounded text-gray-900 focus:border-[#005fb8]"
                />
              </div>
            </div>
          </div>
        </div>
        <div className="p-4 flex justify-end space-x-3 bg-[#f3f3f3] border-t border-gray-200">
          <button
            onClick={onClose}
            className="px-6 py-1.5 shadow-sm text-[13px] font-medium transition-colors bg-white border border-gray-300 rounded text-gray-800 hover:bg-gray-50"
          >
            Cancel
          </button>
          <button
            onClick={onApply}
            className="px-6 py-1.5 shadow-sm text-[13px] font-medium transition-colors bg-[#005fb8] border border-transparent rounded text-white hover:bg-[#0058a6]"
          >
            Apply
          </button>
        </div>
      </div>
    </div>
  );
}
