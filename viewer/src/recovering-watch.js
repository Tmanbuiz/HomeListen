// Firestore listeners stop after a terminal error. Keep pairing while retrying,
// but let the caller suspend audio until fresh access is verified.
export function recoveringWatch(subscribe, next, problem) {
  let closed = false, generation = 0, failures = 0, unsubscribe, retry;
  function connect() {
    if (closed) return;
    const current = ++generation;
    const failed = (error) => {
      if (closed || current !== generation) return;
      generation++;
      unsubscribe?.(); unsubscribe = undefined;
      const delay = [2000, 4000, 8000, 16000, 30000, 60000][Math.min(failures++, 5)];
      retry = setTimeout(connect, delay);
      problem(error);
    };
    try {
      unsubscribe = subscribe((value) => {
        if (closed || current !== generation) return;
        failures = 0;
        next(value);
      }, failed);
    } catch (error) { failed(error); }
  }
  connect();
  return () => {
    closed = true; generation++;
    clearTimeout(retry); unsubscribe?.();
  };
}
