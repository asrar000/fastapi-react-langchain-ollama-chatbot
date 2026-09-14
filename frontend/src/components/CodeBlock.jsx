import { Prism as SyntaxHighlighter } from 'react-syntax-highlighter'
import { oneDark } from 'react-syntax-highlighter/dist/esm/styles/prism'

// react-markdown (v9+) no longer passes an `inline` flag to the `code`
// component, so block vs. inline has to be inferred: a fenced block always
// carries a `language-xxx` className OR spans multiple lines; a genuine
// inline `code` span never does either.
export function Code({ className, children, ...props }) {
  const match = /language-(\w+)/.exec(className || '')
  const text = String(children).replace(/\n$/, '')
  const isBlock = Boolean(match) || text.includes('\n')

  if (!isBlock) {
    return (
      <code className="inline-code" {...props}>
        {children}
      </code>
    )
  }

  return (
    <SyntaxHighlighter
      style={oneDark}
      language={match ? match[1] : 'text'}
      PreTag="div"
      customStyle={{ borderRadius: '8px', fontSize: '0.85rem', margin: '8px 0' }}
    >
      {text}
    </SyntaxHighlighter>
  )
}

// react-markdown wraps fenced blocks in its own <pre>; since SyntaxHighlighter
// already renders its own wrapper (PreTag above), this just passes the
// <code> child through instead of nesting a second one.
export function Pre({ children }) {
  return <>{children}</>
}
