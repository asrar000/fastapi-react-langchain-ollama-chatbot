export default function Sidebar({
  sessions,
  activeSessionId,
  onSelectSession,
  onNewChat,
  onDeleteSession,
}) {
  return (
    <div className="sidebar">
      <button className="new-chat-btn" onClick={onNewChat}>
        New chat
      </button>
      <div className="session-list">
        {sessions.map((session) => (
          <div
            key={session.id}
            className={`session-row ${session.id === activeSessionId ? 'active' : ''}`}
          >
            <button
              className="session-item"
              onClick={() => onSelectSession(session.id)}
              title={session.title || 'New chat'}
            >
              {session.title || 'New chat'}
            </button>
            <button
              className="session-delete"
              onClick={() => onDeleteSession(session.id)}
              aria-label={`Delete ${session.title || 'chat'}`}
            >
              ×
            </button>
          </div>
        ))}
      </div>
    </div>
  )
}
