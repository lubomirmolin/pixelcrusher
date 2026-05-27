import { useState } from 'react';
import { UploadCloud, X } from 'lucide-react';
import './App.css';
import { UpdateRail } from './components/UpdateRail';
import { ProcessedItemsPanel } from './components/ProcessedItemsPanel';
import { CropModal } from './components/CropModal';
import { ResizeModal } from './components/ResizeModal';
import { AutomationSidebar } from './components/AutomationSidebar';
import { BackgroundRemovalModal } from './components/BackgroundRemovalModal';
import { ConversionModal } from './components/ConversionModal';
import { useQueueController } from './features/app/hooks/useQueueController';
import { useUpdateController } from './features/app/hooks/useUpdateController';
import type { CompressionProfileId } from './features/app/types';

function App() {
  const {
    queueState,
    dragState,
    profile,
    setProfile,
    automationActions,
    availableAutomationActions,
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
    backgroundRemovalStatuses,
    backgroundRemovalProgressMessage,
    backgroundRemovalErrorMessage,
    backgroundRemovalRunning,
    activeCropItem,
    activeResizeItem,
    activeBackgroundRemovalItem,
    activeConversionRequest,
    cropDraft,
    setCropDraft,
    resizeDraft,
    setResizeDraft,
    rasterConversionDraft,
    setRasterConversionDraft,
    activePunch,
    activeFolderDrop,
    activeFolderPunch,
    fileInputRef,
    scrollViewportRef,
    processedItems,
    isEmptyState,
    onOpenSystemPicker,
    onOpenFolderPicker,
    onDropFiles,
    onChooseFiles,
    onDragEnter,
    onDragOver,
    onDragLeave,
    openItemCropModal,
    openItemResizeModal,
    openItemBackgroundRemovalModal,
    openItemConversion,
    applyItemCrop,
    applyItemResize,
    applyRasterConversion,
    applyBackgroundRemoval,
    downloadBackgroundRemovalModel,
    addAutomationAction,
    removeAutomationAction,
    moveAutomationAction,
    handlePunchComplete,
    handleFolderPunchComplete,
    clearProcessedItems,
    closeCropModal,
    closeResizeModal,
    closeBackgroundRemovalModal,
    closeConversionModal,
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
  const jobs = Object.values(queueState.jobs);
  const completedJobs = jobs.filter((job) => job.status === 'completed' || job.status === 'failed').length;
  const hasActiveJobs = jobs.some((job) => job.status !== 'completed' && job.status !== 'failed');
  const showBottomHint = !isEmptyState || hasActiveJobs;

  return (
    <div className="h-screen w-screen overflow-hidden bg-[#d7d8db] font-sans antialiased text-[#333]" onDrop={onDropFiles} onDragEnter={onDragEnter} onDragLeave={onDragLeave} onDragOver={onDragOver}>
      <div className="relative flex h-full min-h-0">
        <AutomationSidebar
          actions={automationActions}
          availableActions={availableAutomationActions}
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
          addAutomationAction={addAutomationAction}
          removeAutomationAction={removeAutomationAction}
          moveAutomationAction={moveAutomationAction}
        />

        <main className="relative flex min-w-0 flex-1 flex-col bg-[#ececef]/90">
          <div className="flex h-[58px] items-center justify-between border-b border-black/10 bg-[#f2f3f5]/95 px-5">
            <h1 className="text-[20px] font-semibold tracking-tight text-gray-900">Image Queue</h1>
            <div className="flex items-center gap-3">
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
            </div>
          </div>

          <div className="relative flex min-h-0 flex-1 flex-col">
            {queueState.lastError && (
              <div className="mx-4 mt-4 rounded border border-[#d7364a]/40 bg-[#d7364a]/5 px-3 py-2 text-[12px] text-[#8f1d2a]" role="alert">
                {queueState.lastError}
              </div>
            )}

            {isEmptyState ? (
              <div className="flex flex-1 flex-col items-center justify-center bg-[#e1e2e5]/80 text-gray-400" data-testid="empty-state">
                <div className="mb-4 flex h-[124px] w-[124px] items-center justify-center rounded-[22px] border border-dashed border-gray-400/60 bg-white/45">
                  <UploadCloud size={44} className="text-gray-500" />
                </div>
                <p className="text-[18px] font-semibold text-gray-600">Drag & Drop images here</p>
                <p className="mt-1 text-[16px] text-gray-500">or</p>
                <div className="mt-4 flex items-center gap-2">
                  <button
                    onClick={() => void onOpenSystemPicker()}
                    className="rounded border border-gray-300 bg-white px-4 py-2 text-[14px] font-medium text-gray-800 shadow-sm transition-colors hover:bg-gray-50 active:opacity-80"
                  >
                    Browse Files
                  </button>
                  <button
                    onClick={() => void onOpenFolderPicker()}
                    className="rounded border border-gray-300 bg-white px-4 py-2 text-[14px] font-medium text-gray-800 shadow-sm transition-colors hover:bg-gray-50 active:opacity-80"
                  >
                    Browse Folder
                  </button>
                </div>
              </div>
            ) : (
              <div className="flex min-h-0 flex-1 flex-col gap-4 p-4" data-testid="list-state">
                <ProcessedItemsPanel
                  processedItems={processedItems}
                  queueJobs={queueState.jobs}
                  activeFolderDrop={activeFolderDrop}
                  activeFolderPunch={activeFolderPunch}
                  activePunch={activePunch}
                  onOpenItemCrop={openItemCropModal}
                  onOpenItemResize={openItemResizeModal}
                  onOpenItemBackgroundRemoval={openItemBackgroundRemovalModal}
                  onOpenItemConversion={openItemConversion}
                  onClearProcessedItems={clearProcessedItems}
                  onPunchComplete={handlePunchComplete}
                  onFolderPunchComplete={handleFolderPunchComplete}
                  scrollViewportRef={scrollViewportRef}
                />
              </div>
            )}
          </div>

          {showBottomHint ? (
            <div className="flex min-h-[30px] items-center justify-center gap-2 border-t border-black/10 bg-gradient-to-r from-[#f2f3f5] to-[#e7e8eb] text-[12px] font-medium text-gray-500">
              <span>Drag and drop to process more images</span>
              {jobs.length > 0 && hasActiveJobs ? (
                <>
                  <span>/</span>
                  <span className="font-mono text-[11px]">{completedJobs}/{jobs.length} done</span>
                </>
              ) : null}
            </div>
          ) : null}

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
        </main>
      </div>

      <input
        type="file"
        multiple
        className="hidden"
        ref={fileInputRef}
        onChange={onChooseFiles}
        accept=".png,.jpg,.jpeg,.svg,.gif,.webp"
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
        key={activeCropItem?.id ?? 'crop-modal'}
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

      <BackgroundRemovalModal
        activeItem={activeBackgroundRemovalItem}
        modelStatuses={backgroundRemovalStatuses}
        selectedModel={selectedBackgroundRemovalModel}
        setSelectedModel={setSelectedBackgroundRemovalModel}
        isRunning={backgroundRemovalRunning}
        progressMessage={backgroundRemovalProgressMessage}
        errorMessage={backgroundRemovalErrorMessage}
        onClose={closeBackgroundRemovalModal}
        onDownloadModel={(model) => void downloadBackgroundRemovalModel(model)}
        onQuickRemove={() => void applyBackgroundRemoval(null)}
        onFocusedRemove={(focusRect) => void applyBackgroundRemoval(focusRect)}
      />

      <ConversionModal
        activeRequest={activeConversionRequest}
        draft={rasterConversionDraft}
        onDraftChange={setRasterConversionDraft}
        onClose={closeConversionModal}
        onApply={applyRasterConversion}
      />
    </div>
  );
}

export default App;
