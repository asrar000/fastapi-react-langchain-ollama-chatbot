import { useCallback, useRef, useState } from 'react'
import { getClientId } from '../utils/session'

const API_BASE = import.meta.env.VITE_API_BASE_URL || 'http://localhost:8000'

export function useChat() {
  const [sessions, setSessions] = useState([])
  const [activeSessionId, setActiveSessionId] = useState(null)
  const [messages, setMessages] = useState([])
  const [isStreaming, setIsStreaming] = useState(false)
  const streamingContentRef = useRef('')

  const loadSessions = useCallback(async () => {
    const clientId = getClientId()
    const res = await fetch(`${API_BASE}/api/sessions/?client_id=${clientId}`)
    if (!res.ok) return
    setSessions(await res.json())
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
    return session.id
  }, [])

  const loadMessages = useCallback(async (sessionId) => {
    const clientId = getClientId()
    setActiveSessionId(sessionId)
    const res = await fetch(
      `${API_BASE}/api/sessions/${sessionId}/messages?client_id=${clientId}`,
    )
    if (!res.ok) return
    setMessages(await res.json())
  }, [])

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
      }
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
        { id: assistantId, role: 'assistant', content: '' },
      ])
      setIsStreaming(true)

      const updateAssistant = (text) =>
        setMessages((prev) =>
          prev.map((m) => (m.id === assistantId ? { ...m, content: text } : m)),
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
              updateAssistant(streamingContentRef.current)
            } else if (eventType === 'done') {
              syncSessionAfterTurn(sessionId, parsed.title)
            } else if (eventType === 'error') {
              streamingContentRef.current +=
                `\n\n*The local model didn't respond: ${parsed.error}. ` +
                'Check that Ollama is running.*'
              updateAssistant(streamingContentRef.current)
            }
          }
        }
      } catch (err) {
        updateAssistant(
          `*Couldn't reach the backend: ${err.message}. Is the API running?*`,
        )
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
    isStreaming,
    loadSessions,
    createSession,
    loadMessages,
    deleteSession,
    sendMessage,
  }
}
