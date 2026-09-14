import { useRef } from 'react'

export default function DocumentPanel({
  documents,
  uploadState,
  onUpload,
  onDelete,
}) {
  const inputRef = useRef(null)

  const pick = (e) => {
    const file = e.target.files?.[0]
    if (file) onUpload(file)
    e.target.value = '' // let the same file be re-picked after a failure
  }

  return (
    <div className="doc-panel">
      <div className="doc-row">
        <button
          className="doc-attach"
          onClick={() => inputRef.current?.click()}
          disabled={uploadState.busy}
        >
          {uploadState.busy ? 'Embedding…' : '+ Attach document'}
        </button>

        <input
          ref={inputRef}
          type="file"
          accept=".txt,.md,.markdown,.pdf"
          onChange={pick}
          hidden
        />

        {documents.map((doc) => (
          <span className="doc-chip" key={doc.id}>
            <span className="doc-name" title={doc.filename}>
              {doc.filename}
            </span>
            <span className="doc-count">{doc.chunk_count}</span>
            <button
              className="doc-remove"
              onClick={() => onDelete(doc.id)}
              aria-label={`Remove ${doc.filename}`}
            >
              ×
            </button>
          </span>
        ))}
      </div>

      {uploadState.error && <div className="doc-error">{uploadState.error}</div>}
    </div>
  )
}
