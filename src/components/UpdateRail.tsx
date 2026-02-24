import {
  describeUpdateState,
  installButtonLabel,
  type UpdateFlowState,
} from '../state/updateState';

type UpdateRailProps = {
  appVersion: string;
  updateState: UpdateFlowState;
  onCheckForUpdates: () => void;
  onDownloadUpdate: () => void;
  onInstallUpdate: () => void;
  onOpenReleasePage: (url: string) => void;
};

export function UpdateRail({
  appVersion,
  updateState,
  onCheckForUpdates,
  onDownloadUpdate,
  onInstallUpdate,
  onOpenReleasePage,
}: UpdateRailProps) {
  const checkingLocked =
    updateState.status === 'checking' ||
    updateState.status === 'downloading' ||
    updateState.status === 'installing';

  const releaseUrl =
    updateState.status === 'available' ||
    updateState.status === 'downloading' ||
    updateState.status === 'ready-to-install' ||
    updateState.status === 'installing' ||
    updateState.status === 'action-required'
      ? updateState.releaseUrl
      : updateState.status === 'error'
        ? updateState.releaseUrl
        : undefined;

  return (
    <section className="rail-section">
      <div className="card-header compact-header">
        <h3>Updates</h3>
        <button className="secondary-btn" disabled={checkingLocked} onClick={onCheckForUpdates}>
          {updateState.status === 'checking' ? 'Checking…' : 'Check for Updates'}
        </button>
      </div>
      <p className="update-status-text">{describeUpdateState(updateState, appVersion)}</p>

      {updateState.status === 'available' ? (
        <div className="update-actions">
          <button className="secondary-btn" onClick={onDownloadUpdate}>
            Download Update
          </button>
          <button className="secondary-btn" onClick={() => onOpenReleasePage(updateState.releaseUrl)}>
            Open Release Page
          </button>
        </div>
      ) : null}

      {updateState.status === 'downloading' ? (
        <div className="update-actions">
          <button className="secondary-btn" disabled>
            Downloading…
          </button>
        </div>
      ) : null}

      {updateState.status === 'ready-to-install' ? (
        <div className="update-actions">
          <button className="secondary-btn" onClick={onInstallUpdate}>
            {installButtonLabel(updateState)}
          </button>
          <button className="secondary-btn" onClick={() => onOpenReleasePage(updateState.releaseUrl)}>
            Open Release Page
          </button>
        </div>
      ) : null}

      {updateState.status === 'action-required' && updateState.command ? (
        <pre className="update-guidance" aria-label="update-guidance-command">
          {updateState.command}
        </pre>
      ) : null}

      {(updateState.status === 'error' || updateState.status === 'action-required') && releaseUrl ? (
        <div className="update-actions">
          <button className="secondary-btn" onClick={() => onOpenReleasePage(releaseUrl)}>
            Open Release Page
          </button>
        </div>
      ) : null}
    </section>
  );
}
