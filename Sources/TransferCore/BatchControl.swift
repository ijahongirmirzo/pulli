/// User actions on a batch that touch both the journal and the destination.
public enum BatchControl {
    /// Cancels a batch (stop its supervisor first). Partial files are kept for a later resume
    /// unless `discardParts` (brief: "keep .part files so it can resume later, with an option to
    /// discard them").
    public static func cancel(batchID: Int64, journal: Journal, sink: any FileSink, discardParts: Bool) throws {
        let jobs = try journal.cancelBatch(batchID, discardingParts: discardParts)
        guard discardParts else { return }
        for job in jobs {
            sink.remove(job.partURL)
        }
    }
}
