import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

export function useSyncedDraft(source) {
  const sourceRef = useRef(source);
  sourceRef.current = source;
  const sourceKey = useMemo(() => JSON.stringify(source), [source]);
  const [draft, setDraftState] = useState(source);
  const [dirty, setDirty] = useState(false);

  useEffect(() => {
    if (!dirty) setDraftState(sourceRef.current);
  }, [dirty, sourceKey]);

  const setDraft = useCallback((next) => {
    setDirty(true);
    setDraftState(next);
  }, []);

  const markClean = useCallback(() => setDirty(false), []);
  const reset = useCallback(() => {
    setDraftState(sourceRef.current);
    setDirty(false);
  }, [sourceKey]);

  return { draft, setDraft, dirty, markClean, reset };
}
