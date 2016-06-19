package ghcvm.runtime.stm;

import java.util.Stack;
import java.util.ListIterator;
import java.util.concurrent.atomic.AtomicBoolean;

import ghcvm.runtime.RtsFlags;
import ghcvm.runtime.stg.StgTSO;
import ghcvm.runtime.stg.Capability;
import ghcvm.runtime.stg.StgClosure;
import ghcvm.runtime.stg.StgContext;
import ghcvm.runtime.exception.StgException;
import ghcvm.runtime.apply.Apply;

public class STM {
    public static long TOKEN_BATCH_SIZE = 1024;
    public static long maxCommits = 0;
    public static AtomicBoolean tokenLocked = new AtomicBoolean(false);
    public static final boolean configUseReadPhase = false;
    public static final boolean doShake = false;
    public static int shakeCounter = 0;
    public static int shakeLimit = 1;

    public static boolean shake() {
        if (doShake) {
            if (((shakeCounter++) % shakeLimit) == 0) {
                shakeCounter = 1;
                shakeLimit++;
            }
        }
        return false;
    }

    public static void lock(StgTRecHeader trec) {}
    public static void unlock(StgTRecHeader trec) {}

    public static boolean watcherIsInvariant(StgClosure c) {
        //TODO: Better condition
        return (c.getClass() == StgAtomicInvariant.class);
    }

    public static boolean watcherIsTSO(StgClosure c) {
        //TODO: Better condition
        return (c.getClass() == StgTSO.class);
    }

    public static class EntrySearchResult {
        public final StgTRecHeader header;
        public final TRecEntry entry;
        public EntrySearchResult(final StgTRecHeader header, final TRecEntry entry) {
            this.header = header;
            this.entry = entry;
        }
    }

    public static EntrySearchResult getEntry(Stack<StgTRecHeader> trecStack, StgTVar tvar) {

        ListIterator<StgTRecHeader> it = trecStack.listIterator(trecStack.size());
        EntrySearchResult result = null;
        loop:
        while (result == null && it.hasPrevious()) {
            StgTRecHeader trec = it.previous();
            Stack<StgTRecChunk> chunkStack = trec.chunkStack;
            ListIterator<StgTRecChunk> cit = chunkStack.listIterator(chunkStack.size());
            while (cit.hasPrevious()) {
                StgTRecChunk chunk = cit.previous();
                for (TRecEntry entry: chunk.entries) {
                    // Traversal
                    if (entry.tvar == tvar) {
                        result = new EntrySearchResult(trec, entry);
                        break loop;
                    }
                }
            }
        }
        return result;
    }

    public static StgClosure readCurrentValue(StgTRecHeader trec, StgTVar tvar) {
        StgClosure result = tvar.currentValue;
        if (RtsFlags.STM.fineGrained) {
            while (result.isTrecHeader()) {
                result = tvar.currentValue;
            }
        }
        return result;
    }

    public static StgClosure newTVar = new StgClosure() {
            @Override
            public final void enter(StgContext context) {
                StgClosure init = context.R1;
                context.R1 = new StgTVar(init);
            }
        };

    public static StgClosure readTVar = new StgClosure() {
            @Override
            public final void enter(StgContext context) {
                Capability cap = context.myCapability;
                StgTSO tso = context.currentTSO;
                StgTVar tvar = (StgTVar) context.R1;
                context.R1 = cap.stmReadTvar(tso.trec, tvar);
            }
        };

    public static StgClosure readTVarIO = new StgClosure() {
            @Override
            public final void enter(StgContext context) {
                StgClosure result;
                StgTVar tvar = (StgTVar) context.R1;
                do {
                    result = tvar.currentValue;
                } while (!result.isTrecHeader());
                context.R1 = result;
            }
        };

    public static StgClosure writeTVar = new StgClosure() {
            @Override
            public final void enter(StgContext context) {
                Capability cap = context.myCapability;
                StgTSO tso = context.currentTSO;
                StgTVar tvar = (StgTVar) context.R1;
                StgClosure newValue = context.R2;
                cap.stmWriteTvar(tso.trec, tvar, newValue);
            }
        };

    public static StgClosure check = new StgClosure() {
            @Override
            public final void enter(StgContext context) {
                Capability cap = context.myCapability;
                StgTSO tso = context.currentTSO;
                StgClosure closure = context.R1;
                cap.stmAddInvariantToCheck(tso.trec.peek(), closure);
            }
        };

    public static StgClosure atomically = new StgClosure() {
            @Override
            public final void enter(StgContext context) {
                StgTSO tso = context.currentTSO;
                if (tso.trec.peek() != null) {
                    context.R1 = null; /* TODO: base_ControlziExceptionziBase_nestedAtomically_closure */
                    StgException.raise.enter(context);
                } else {
                    Capability cap = context.myCapability;
                    StgClosure stm = context.R1;
                    StgTRecHeader newTrec = cap.stmStartTransaction(null);
                    tso.trec.push(newTrec);
                    tso.sp.add(new StgAtomicallyFrame(stm));
                    Apply.ap_v_fast.enter(context);
                }
            }
        };

    public static StgClosure catchSTM = new StgClosure() {
            @Override
            public final void enter(StgContext context) {
                StgClosure code = context.R1;
                StgClosure handler = context.R2;
                Capability cap = context.myCapability;
                StgTSO tso = context.currentTSO;
                StgTRecHeader newTrec = cap.stmStartTransaction(tso.trec.peek());
                tso.trec.push(newTrec);
                tso.sp.add(new StgCatchSTMFrame(code, handler));
                Apply.ap_v_fast.enter(context);
            }
        };

    public static StgClosure catchRetry = new StgClosure() {
            @Override
            public final void enter(StgContext context) {
                StgClosure firstCode = context.R1;
                StgClosure altCode = context.R2;
                Capability cap = context.myCapability;
                StgTSO tso = context.currentTSO;
                StgTRecHeader newTrec = cap.stmStartTransaction(tso.trec.peek());
                tso.trec.push(newTrec);
                tso.sp.add(new StgCatchRetryFrame(firstCode, altCode));
                Apply.ap_v_fast.enter(context);
            }
        };
}
