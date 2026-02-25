import { useState } from 'react';
import { UploadCloud, X } from 'lucide-react';
import './App.css';
import { UpdateRail } from './components/UpdateRail';
import { ProcessedItemsPanel } from './components/ProcessedItemsPanel';
import { CropModal } from './components/CropModal';
import { ResizeModal } from './components/ResizeModal';
import { useQueueController } from './features/app/hooks/useQueueController';
import { useUpdateController } from './features/app/hooks/useUpdateController';
import type { CompressionProfileId } from './features/app/types';

function App() {
  const {
    queueState,
    dragState,
    profile,
    setProfile,
    autoCrop,
    activeCropItem,
    activeResizeItem,
    cropDraft,
    setCropDraft,
    resizeDraft,
    setResizeDraft,
    activePunch,
    fileInputRef,
    scrollViewportRef,
    processedItems,
    isEmptyState,
    onOpenSystemPicker,
    onDropFiles,
    onChooseFiles,
    onDragEnter,
    onDragOver,
    onDragLeave,
    openItemCropModal,
    openItemResizeModal,
    applyItemCrop,
    applyItemResize,
    handlePunchComplete,
    clearProcessedItems,
    closeCropModal,
    closeResizeModal,
  } = useQueueController();

  const {
    appVersion,
    updateState,
    onCheckForUpdates,
    onDownloadUpdate,
    onInstallUpdate,
    openReleasePage,
  } = useUpdateController();

  const [showUpdateSheet, setShowUpdateSheet] = useState(false);

  return (
    <div className="h-screen w-screen flex flex-col bg-[#f3f3f3] font-sans antialiased text-[#333] transition-colors duration-300 overflow-hidden" onDrop={onDropFiles} onDragEnter={onDragEnter} onDragLeave={onDragLeave} onDragOver={onDragOver}>
      <div className="flex-1 overflow-hidden relative flex flex-col">
        <div className="flex-1 overflow-y-auto relative flex flex-col px-6 py-4">
          <div className="flex justify-between items-end mb-6">
            <h1 className="text-2xl font-semibold text-gray-900 tracking-tight">Image Queue</h1>
            <div className="flex space-x-3 items-center">
              <select
                value={profile}
                onChange={(event) => setProfile(event.target.value as CompressionProfileId)}
                aria-label="Compression profile"
                className="bg-white border border-gray-300 rounded shadow-sm text-[13px] px-3 py-1.5 outline-none focus:ring-2 focus:ring-[#005fb8]/50 appearance-none pr-8 cursor-pointer text-gray-800"
                style={{ backgroundImage: 'url("data:image/svg+xml,%3Csvg xmlns=\'http://www.w3.org/2000/svg\' width=\'12\' height=\'12\' fill=\'none\' stroke=\'%23333\' stroke-width=\'2\' stroke-linecap=\'round\' stroke-linejoin=\'round\'%3E%3Cpath d=\'M3 5l3 3 3-3\'/%3E%3C/svg%3E")', backgroundPosition: 'right 8px center', backgroundRepeat: 'no-repeat', backgroundSize: '12px' }}
              >
                <option value="high">High Quality</option>
                <option value="balanced">Balanced</option>
                <option value="smallest">Smallest Size</option>
              </select>
              <button
                className="bg-[#005fb8] text-white font-semibold rounded text-[13px] px-4 py-1.5 shadow-sm hover:bg-[#0058a6] transition-colors"
                onClick={() => setShowUpdateSheet(true)}
              >
                Update
              </button>
              <label className="sr-only">
                <input
                  type="checkbox"
                  checked={autoCrop}
                  readOnly
                  aria-label="Autocrop"
                />
                Autocrop
              </label>
            </div>
          </div>

          {queueState.lastError && (
            <div className="mb-4 rounded border border-[#d7364a]/40 bg-[#d7364a]/5 px-3 py-2 text-[12px] text-[#8f1d2a]" role="alert">
              {queueState.lastError}
            </div>
          )}

          {isEmptyState ? (
            <div className="flex flex-col items-center justify-center text-gray-400 flex-1 border border-dashed border-gray-300 rounded-xl bg-white/50 mb-4" data-testid="empty-state">
              <div className="w-24 h-24 mb-4 flex items-center justify-center shadow-sm rounded-xl bg-white border border-gray-200">
                <UploadCloud size={40} className="text-[#005fb8]" />
              </div>
              <p className="text-[14px] font-medium text-gray-800">Drag & Drop images here</p>
              <p className="text-[12px] mt-1">or</p>
              <button
                onClick={() => void onOpenSystemPicker()}
                className="mt-3 px-4 py-1.5 shadow-sm text-[13px] font-medium transition-colors bg-[#005fb8] border border-transparent rounded text-white hover:bg-[#0058a6] active:opacity-80"
              >
                Browse Files
              </button>
            </div>
          ) : (
            <div className="flex flex-col flex-1 gap-4 min-h-0" data-testid="list-state">
              <ProcessedItemsPanel
                processedItems={processedItems}
                activePunch={activePunch}
                onOpenItemCrop={openItemCropModal}
                onOpenItemResize={openItemResizeModal}
                onClearProcessedItems={clearProcessedItems}
                onPunchComplete={handlePunchComplete}
                scrollViewportRef={scrollViewportRef}
              />
            </div>
          )}
        </div>

        {dragState !== 'idle' && (
          <div className={`absolute inset-0 border-4 border-dashed m-4 flex items-center justify-center z-50 backdrop-blur-[2px] transition-all ${dragState === 'unsupported' ? 'bg-[#d7364a]/5 border-[#d7364a]/40' : 'bg-[#005fb8]/5 border-[#005fb8]/40'} rounded-xl`}>
            <div className="px-6 py-3 shadow-lg font-medium text-[14px] flex items-center bg-white rounded-md text-[#005fb8]">
              {dragState === 'unsupported' ? (
                <>Unsupported format</>
              ) : (
                <><UploadCloud size={18} className="mr-2" /> Drop to crush</>
              )}
            </div>
          </div>
        )}
      </div>

      <input
        type="file"
        multiple
        className="hidden"
        ref={fileInputRef}
        onChange={onChooseFiles}
        accept=".png,.jpg,.jpeg,.svg,.gif"
      />

      {showUpdateSheet && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm" role="dialog" aria-label="updates-modal">
          <div className="w-[400px] shadow-2xl overflow-hidden flex flex-col transform transition-all rounded-lg bg-white border border-gray-300">
            <div className="h-12 flex items-center justify-between px-6 relative">
              <span className="font-semibold text-gray-900 text-[15px]">Updates</span>
              <button onClick={() => setShowUpdateSheet(false)} className="text-gray-500 hover:text-[#e81123] hover:bg-black/5 p-1 rounded transition-colors">
                <X size={16} />
              </button>
            </div>
            <div className="p-6 flex-1 bg-white">
              <UpdateRail
                appVersion={appVersion}
                updateState={updateState}
                onCheckForUpdates={() => void onCheckForUpdates()}
                onDownloadUpdate={() => void onDownloadUpdate()}
                onInstallUpdate={() => void onInstallUpdate()}
                onOpenReleasePage={(url) => void openReleasePage(url)}
              />
            </div>
          </div>
        </div>
      )}

      <CropModal
        activeItem={activeCropItem}
        draft={cropDraft}
        onDraftChange={setCropDraft}
        onClose={closeCropModal}
        onApply={applyItemCrop}
      />

      <ResizeModal
        activeItem={activeResizeItem}
        draft={resizeDraft}
        onDraftChange={setResizeDraft}
        onClose={closeResizeModal}
        onApply={applyItemResize}
      />
    </div>
  );
}

export default App;
