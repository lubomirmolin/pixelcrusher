import { Hand, FolderOpen } from 'lucide-react';
import { useEffect } from 'react';

type FolderPunchAnimationProps = {
  folderName: string;
  onComplete: () => void;
};

export function FolderPunchAnimation({ folderName, onComplete }: FolderPunchAnimationProps) {
  useEffect(() => {
    const timer = window.setTimeout(() => {
      onComplete();
    }, 1150);

    return () => {
      window.clearTimeout(timer);
    };
  }, [onComplete]);

  return (
    <div className="w-full flex flex-col items-center mt-2">
      <div className="folder-drop-scene">
        <div className="folder-drop-folder">
          <FolderOpen size={84} strokeWidth={1.6} />
        </div>
        <div className="folder-drop-hand">
          <Hand size={56} strokeWidth={1.8} />
        </div>
        <div className="folder-drop-shadow" />
      </div>
      <p className="mt-2 text-sm text-gray-600">
        Dropped folder: <span className="font-semibold text-gray-900">{folderName}</span>
      </p>
    </div>
  );
}
