import { useEffect } from 'react'
import Sidebar from './components/Sidebar'
import MessageList from './components/MessageList'
import MessageInput from './components/MessageInput'
import { useChat } from './hooks/useChat'
import './styles/App.css'

export default function App() {
  const {
    sessions,
    activeSessionId,
    messages,
    isStreaming,
    loadSessions,
    createSession,
    loadMessages,
    deleteSession,
    sendMessage,
  } = useChat()

  useEffect(() => {
    loadSessions()
  }, [loadSessions])

  return (
    <div className="app">
      <Sidebar
        sessions={sessions}
        activeSessionId={activeSessionId}
        onSelectSession={loadMessages}
        onNewChat={createSession}
        onDeleteSession={deleteSession}
      />
      <div className="chat-canvas">
        <MessageList messages={messages} isStreaming={isStreaming} />
        <MessageInput onSend={sendMessage} disabled={isStreaming} />
      </div>
    </div>
  )
}
