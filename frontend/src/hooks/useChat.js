import { useCallback, useRef, useState } from 'react'
import { getClientId } from '../utils/session'

const API_BASE = import.meta.env.VITE_API_BASE_URL || 'http://localhost:8000'

export function useChat() {
  const [sessions, setSessions] = useState([])
  const [activeSessionId, setActiveSessionId] = useState(null)
  const [messages, setMessages] = useState([])
  const [documents, setDocuments] = useState([])
  const [isStreaming, setIsStreaming] = useState(false)
  const [uploadState, setUploadState] = useState({ busy: false, error: null })
  const streamingContentRef = useRef('')

  const loadSessions = useCallback(async () => {
    const clientId = getClientId()
    const res = await fetch(`${API_BASE}/api/sessions/?client_id=${clientId}`)
    if (!res.ok) return
    setSessions(await res.json())
  }, [])

  const loadDocuments = useCallback(async (sessionId) => {
    if (!sessionId) {
      setDocuments([])
      return
    }
    const clientId = getClientId()
    const res = await fetch(
      `${API_BASE}/api/documents/?session_id=${sessionId}&client_id=${clientId}`,
    )
    if (!res.ok) return
    setDocuments(await res.json())
  }, [])

  const createSession = useCallback(async () => {
    const clientId = getClientId()
    const res = await fetch(`${API_BASE}/api/sessions/`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ client_id: clientId, title: 'New chat' }),
    })
    const session = await res.json()
    setSessions((prev) => [session, ...prev])
    setActiveSessionId(session.id)
    setMessages([])
    setDocuments([])
    setUploadState({ busy: false, error: null })
    return session.id
  }, [])

  const loadMessages = useCallback(
    async (sessionId) => {
      const clientId = getClientId()
      setActiveSessionId(sessionId)
      setUploadState({ busy: false, error: null })
      const res = await fetch(
        `${API_BASE}/api/sessions/${sessionId}/messages?client_id=${clientId}`,
      )
      if (res.ok) setMessages(await res.json())
      loadDocuments(sessionId)
    },
    [loadDocuments],
  )

  const deleteSession = useCallback(
    async (sessionId) => {
      const clientId = getClientId()
      const res = await fetch(
        `${API_BASE}/api/sessions/${sessionId}?client_id=${clientId}`,
        { method: 'DELETE' },
      )
      if (!res.ok) return
      setSessions((prev) => prev.filter((s) => s.id !== sessionId))
      if (sessionId === activeSessionId) {
        setActiveSessionId(null)
        setMessages([])
        setDocuments([])
      }
    },
    [activeSessionId],
  )

  // Uploading is synchronous on the backend: it chunks, embeds every chunk,
  // and only then responds. Keep the button disabled for the whole round trip.
  const uploadDocument = useCallback(
    async (file) => {
      let sessionId = activeSessionId
      if (!sessionId) sessionId = await createSession()

      const clientId = getClientId()
      const form = new FormData()
      form.append('file', file)

      setUploadState({ busy: true, error: null })
      try {
        const res = await fetch(
          `${API_BASE}/api/documents/?session_id=${sessionId}&client_id=${clientId}`,
          { method: 'POST', body: form },
        )
        if (!res.ok) {
          const detail = await res.json().catch(() => ({}))
          throw new Error(detail.detail || `Upload failed (${res.status})`)
        }
        const doc = await res.json()
        setDocuments((prev) => [doc, ...prev])
        setUploadState({ busy: false, error: null })
      } catch (err) {
        setUploadState({ busy: false, error: err.message })
      }
    },
    [activeSessionId, createSession],
  )

  const deleteDocument = useCallback(
    async (documentId) => {
      if (!activeSessionId) return
      const clientId = getClientId()
      const res = await fetch(
        `${API_BASE}/api/documents/${documentId}?session_id=${activeSessionId}&client_id=${clientId}`,
        { method: 'DELETE' },
      )
      if (!res.ok) return
      setDocuments((prev) => prev.filter((d) => d.id !== documentId))
    },
    [activeSessionId],
  )

  // The backend renames a session from its first message and bumps
  // updated_at. Mirror both locally when the turn finishes, so the sidebar
  // stops showing "New chat" without needing a page reload.
  const syncSessionAfterTurn = useCallback((sessionId, title) => {
    setSessions((prev) => {
      const target = prev.find((s) => s.id === sessionId)
      if (!target) return prev
      const updated = title ? { ...target, title } : target
      return [updated, ...prev.filter((s) => s.id !== sessionId)]
    })
  }, [])

  const sendMessage = useCallback(
    async (content) => {
      const clientId = getClientId()
      let sessionId = activeSessionId
      if (!sessionId) {
        sessionId = await createSession()
      }

      const userMsg = { id: crypto.randomUUID(), role: 'user', content }
      const assistantId = crypto.randomUUID()
      streamingContentRef.current = ''

      setMessages((prev) => [
        ...prev,
        userMsg,
        { id: assistantId, role: 'assistant', content: '', sources: [] },
      ])
      setIsStreaming(true)

      const patchAssistant = (patch) =>
        setMessages((prev) =>
          prev.map((m) => (m.id === assistantId ? { ...m, ...patch } : m)),
        )

      try {
        const response = await fetch(`${API_BASE}/api/chat/stream`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            session_id: sessionId,
            client_id: clientId,
            message: content,
          }),
        })

        if (!response.ok || !response.body) {
          throw new Error(`Request failed (${response.status})`)
        }

        const reader = response.body.getReader()
        const decoder = new TextDecoder()
        let buffer = ''

        while (true) {
          const { done, value } = await reader.read()
          if (done) break

          buffer += decoder.decode(value, { stream: true })
          // sse-starlette emits CRLF line endings, so split on either form.
          // Splitting only on complete separators leaves any partial event
          // in the buffer for the next chunk.
          const events = buffer.split(/\r?\n\r?\n/)
          buffer = events.pop() ?? ''

          for (const rawEvent of events) {
            if (!rawEvent.trim()) continue

            let eventType = 'message'
            let data = null
            for (const line of rawEvent.split(/\r?\n/)) {
              if (line.startsWith('event:')) eventType = line.slice(6).trim()
              if (line.startsWith('data:')) data = line.slice(5).trim()
            }
            if (!data) continue
            const parsed = JSON.parse(data)

            if (eventType === 'token') {
              streamingContentRef.current += parsed.content
              patchAssistant({ content: streamingContentRef.current })
            } else if (eventType === 'sources') {
              patchAssistant({ sources: parsed.sources })
            } else if (eventType === 'done') {
              syncSessionAfterTurn(sessionId, parsed.title)
            } else if (eventType === 'error') {
              streamingContentRef.current +=
                `\n\n*The local model didn't respond: ${parsed.error}. ` +
                'Check that Ollama is running.*'
              patchAssistant({ content: streamingContentRef.current })
            }
          }
        }
      } catch (err) {
        patchAssistant({
          content: `*Couldn't reach the backend: ${err.message}. Is the API running?*`,
        })
      } finally {
        setIsStreaming(false)
      }
    },
    [activeSessionId, createSession, syncSessionAfterTurn],
  )

  return {
    sessions,
    activeSessionId,
    messages,
    documents,
    isStreaming,
    uploadState,
    loadSessions,
    createSession,
    loadMessages,
    deleteSession,
    uploadDocument,
    deleteDocument,
    sendMessage,
  }
}
