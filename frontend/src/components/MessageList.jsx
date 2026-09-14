import { useEffect, useRef } from 'react'
import Markdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { Code, Pre } from './CodeBlock'

function Sources({ sources }) {
  if (!sources?.length) return null
  return (
    <div className="sources">
      <span className="sources-label">based on</span>
      {sources.map((s, i) => (
        <span className="source-chip" key={`${s.filename}-${i}`}>
          {s.filename}
          <span className="source-score">{s.similarity}</span>
        </span>
      ))}
    </div>
  )
}

export default function MessageList({ messages, isStreaming }) {
  const bottomRef = useRef(null)

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages])

  if (messages.length === 0) {
    return (
      <div className="message-list">
        <div className="empty-state">
          <p>
            Ask anything — the model runs locally, nothing leaves this machine.
            Attach a document to ground answers in it.
          </p>
        </div>
      </div>
    )
  }

  return (
    <div className="message-list">
      {messages.map((msg, i) => {
        const isLast = i === messages.length - 1
        const isPending =
          isLast && msg.role === 'assistant' && isStreaming && !msg.content
        return (
          <div key={msg.id} className={`message message-${msg.role}`}>
            <div className="message-role">
              {msg.role === 'user' ? 'you' : 'assistant'}
            </div>
            <div className="message-content">
              {isPending ? (
                <span className="thinking-dots" aria-label="Waiting for response">
                  <span />
                  <span />
                  <span />
                </span>
              ) : (
                <>
                  <Markdown
                    remarkPlugins={[remarkGfm]}
                    components={{ code: Code, pre: Pre }}
                  >
                    {msg.content}
                  </Markdown>
                  <Sources sources={msg.sources} />
                </>
              )}
            </div>
          </div>
        )
      })}
      <div ref={bottomRef} />
    </div>
  )
}
