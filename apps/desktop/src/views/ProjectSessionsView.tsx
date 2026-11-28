import {
  Check,
  ChevronDown,
  ChevronRight,
  Folder,
  FolderOpen,
  Lock,
  LockOpen,
  MessageSquareText,
} from 'lucide-react';
import { useCallback, useEffect, useState } from 'react';
import { abbreviatePath, formatBytes, formatDateTime, revealActionTitle } from '../lib/format';
import { RECOMMENDATION_COLORS } from '../lib/theme';
import { ScanNotFoundError, type CoreClient } from '../rpc/client';
import type {
  CleanableItemDTO,
  ClientSummaryDTO,
  ItemAgeFilter,
  PlatformKind,
  ProjectSummaryDTO,
} from '../rpc/types';

interface ProjectSessionsViewProps {
  core: CoreClient;
  scanId: string | null;
  client: ClientSummaryDTO | null;
  reportRevision: number;
  selectionRevision: number;
  isBusy: boolean;
  platform: PlatformKind;
  onBackToClient: () => void;
  onToggleSessionItem: (item: CleanableItemDTO, projectId: string, showsAllClients: boolean) => Promise<void>;
  onSelectAllSessions: (sessions: CleanableItemDTO[], projectId: string, showsAllClients: boolean) => Promise<void>;
  onToggleProtection: (projectId: string, nextProtected: boolean) => Promise<void>;
  onInspectFullTitle: (item: CleanableItemDTO) => void;
  onRevealItem: (item: CleanableItemDTO) => void;
  onScanNotFound: (error: ScanNotFoundError) => void;
  onStartScan: () => void;
}

export function ProjectSessionsView({
  core,
  scanId,
  client,
  reportRevision,
  selectionRevision,
  isBusy,
  platform,
  onBackToClient,
  onToggleSessionItem,
  onSelectAllSessions,
  onToggleProtection,
  onInspectFullTitle,
  onRevealItem,
  onScanNotFound,
  onStartScan,
}: ProjectSessionsViewProps) {
  const [projects, setProjects] = useState<ProjectSummaryDTO[]>([]);
  const [selectedProjectId, setSelectedProjectId] = useState<string | null>(null);
  const [showsAllClients, setShowsAllClients] = useState(false);
  const [ageFilter, setAgeFilter] = useState<ItemAgeFilter>('all');
  const [sessions, setSessions] = useState<CleanableItemDTO[]>([]);
  const [expandedSessionId, setExpandedSessionId] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const loadProjects = useCallback(async () => {
    if (!scanId || !client) {
      setProjects([]);
      return;
    }
    try {
      const res = await core.listProjects({
        scanId,
        clientId: client.id,
        includeAllClients: showsAllClients,
      });
      setProjects(res.projects);
      setSelectedProjectId((prev) => {
        if (prev && res.projects.some((p) => p.projectId === prev)) return prev;
        return res.projects[0]?.projectId ?? null;
      });
    } catch (err) {
      if (err instanceof ScanNotFoundError) {
        onScanNotFound(err);
        return;
      }
      setProjects([]);
    }
  }, [core, scanId, client, showsAllClients, onScanNotFound]);

  useEffect(() => {
    void loadProjects();
  }, [loadProjects, reportRevision]);

  const activeProject = projects.find((p) => p.projectId === selectedProjectId) ?? null;

  const loadSessions = useCallback(async () => {
    if (!scanId || !client || !selectedProjectId) {
      setSessions([]);
      return;
    }
    setLoading(true);
    try {
      const res = await core.queryProjectSessions({
        scanId,
        projectId: selectedProjectId,
        clientId: showsAllClients && activeProject?.workspacePath ? null : client.id,
        filter: ageFilter === 'all' ? null : { age: ageFilter },
        sort: 'modifiedDesc',
        offset: 0,
        limit: 200,
      });
      setSessions(res.items);
    } catch (err) {
      if (err instanceof ScanNotFoundError) {
        onScanNotFound(err);
        return;
      }
      setSessions([]);
    } finally {
      setLoading(false);
    }
  }, [core, scanId, client, selectedProjectId, showsAllClients, activeProject?.workspacePath, ageFilter, onScanNotFound]);

  useEffect(() => {
    void loadSessions();
  }, [loadSessions, reportRevision, selectionRevision]);

  useEffect(() => {
    setExpandedSessionId(null);
  }, [selectedProjectId]);

  if (!scanId) {
    return (
      <div className="hero-center-stage" data-testid="projects-empty-noscan">
        <h3 style={{ margin: 0 }}>项目会话</h3>
        <p style={{ margin: 0, color: 'var(--text-secondary)' }}>扫描本机 AI 客户端后，即可按工作区浏览并保护会话。</p>
        <button type="button" className="btn-glow-primary" onClick={onStartScan}>
          开始扫描
        </button>
      </div>
    );
  }

  if (projects.length === 0) {
    return (
      <div className="hero-center-stage" data-testid="projects-empty">
        <h3 style={{ margin: 0 }}>此客户端没有项目会话</h3>
        <button type="button" className="btn-subtle-pill" onClick={onBackToClient}>
          返回清理条目
        </button>
      </div>
    );
  }

  const bulkSelectableSessions = sessions.filter((s) => s.bulkSelectable && !s.hardProtectionReason);

  return (
    <div className="projects-split" data-testid="project-sessions-view">
      <div className="page-scroll projects-left">
        <div
          className="page-scroll-header"
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: '14px 14px 10px',
          }}
        >
          <strong style={{ fontSize: 14 }}>项目</strong>
          <button
            type="button"
            style={{ border: 'none', background: 'transparent', color: 'var(--accent-blue)', fontSize: 12 }}
            onClick={onBackToClient}
            data-testid="back-to-cleanup-items-btn"
          >
            返回清理条目
          </button>
        </div>

        <div style={{ padding: '0 8px 96px', display: 'flex', flexDirection: 'column', gap: 3 }}>
          {projects.map((project) => {
            const isSelected = project.projectId === selectedProjectId;
            return (
              <button
                key={project.projectId}
                type="button"
                onClick={() => setSelectedProjectId(project.projectId)}
                style={{
                  width: '100%',
                  border: 'none',
                  borderRadius: 8,
                  padding: '8px 9px',
                  textAlign: 'left',
                  background: isSelected ? 'rgba(59, 130, 246, 0.14)' : 'transparent',
                  display: 'flex',
                  flexDirection: 'column',
                  gap: 3,
                }}
                data-testid={`project-row-${project.name}`}
              >
                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  {project.isProtected ? (
                    <Lock size={13} style={{ color: 'var(--accent-risk)', flexShrink: 0 }} />
                  ) : (
                    <Folder size={13} style={{ color: isSelected ? 'var(--accent-blue)' : 'var(--text-secondary)', flexShrink: 0 }} />
                  )}
                  <span
                    style={{
                      flex: 1,
                      fontWeight: isSelected ? 600 : 500,
                      overflow: 'hidden',
                      textOverflow: 'ellipsis',
                      whiteSpace: 'nowrap',
                    }}
                  >
                    {project.name}
                  </span>
                  <span className="mono-num" style={{ fontSize: 11.5, color: 'var(--text-secondary)' }}>
                    {project.sessionCount}
                  </span>
                </div>
                {project.workspacePath && (
                  <div
                    className="mono-path"
                    style={{
                      fontSize: 10.5,
                      color: 'var(--text-tertiary)',
                      overflow: 'hidden',
                      textOverflow: 'ellipsis',
                      whiteSpace: 'nowrap',
                    }}
                    title={project.workspacePath}
                  >
                    {abbreviatePath(project.workspacePath, platform)}
                  </div>
                )}
              </button>
            );
          })}
        </div>
      </div>

      <div className="page-scroll projects-right">
        {activeProject && (
          <>
            <div
              className="page-scroll-header"
              style={{ padding: 16, borderBottom: '1px solid var(--divider)', display: 'flex', flexDirection: 'column', gap: 10 }}
            >
              <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12 }}>
                <div style={{ minWidth: 0 }}>
                  <h2 style={{ margin: '0 0 3px', fontSize: 20, fontWeight: 700 }}>{activeProject.name}</h2>
                  {activeProject.workspacePath && (
                    <div
                      className="mono-path"
                      style={{
                        fontSize: 11.5,
                        color: 'var(--text-secondary)',
                        userSelect: 'text',
                        wordBreak: 'break-all',
                      }}
                    >
                      {activeProject.workspacePath}
                    </div>
                  )}
                </div>

                {activeProject.workspacePath && (
                  <button
                    type="button"
                    className="toolbar-btn"
                    disabled={isBusy}
                    onClick={() => void onToggleProtection(activeProject.projectId, !activeProject.isProtected)}
                    data-testid="toggle-project-protection-btn"
                  >
                    {activeProject.isProtected ? <LockOpen size={13} /> : <Lock size={13} />}
                    <span>{activeProject.isProtected ? '解除保护' : '保护此项目'}</span>
                  </button>
                )}
              </div>

              {activeProject.isProtected && (
                <div
                  style={{
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: 6,
                    fontSize: 12,
                    color: 'var(--accent-risk)',
                  }}
                  data-testid="project-protected-banner"
                >
                  <Lock size={13} />
                  <span>此项目在所有客户端的会话与专属关联文件已锁定</span>
                </div>
              )}

              <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
                {activeProject.workspacePath && client && (
                  <div className="segmented-track">
                    <button
                      type="button"
                      className={`segmented-btn ${!showsAllClients ? 'active' : ''}`}
                      onClick={() => setShowsAllClients(false)}
                    >
                      {client.name}
                    </button>
                    <button
                      type="button"
                      className={`segmented-btn ${showsAllClients ? 'active' : ''}`}
                      onClick={() => setShowsAllClients(true)}
                    >
                      所有客户端
                    </button>
                  </div>
                )}

                <div className="segmented-track">
                  <button
                    type="button"
                    className={`segmented-btn ${ageFilter === 'all' ? 'active' : ''}`}
                    onClick={() => setAgeFilter('all')}
                  >
                    全部
                  </button>
                  <button
                    type="button"
                    className={`segmented-btn ${ageFilter === 'olderThan90Days' ? 'active' : ''}`}
                    onClick={() => setAgeFilter('olderThan90Days')}
                  >
                    90 天前
                  </button>
                </div>

                <span style={{ flex: 1 }} />

                <button
                  type="button"
                  className="btn-subtle-pill"
                  disabled={bulkSelectableSessions.length === 0 || isBusy}
                  onClick={() => void onSelectAllSessions(sessions, activeProject.projectId, showsAllClients)}
                  data-testid="select-all-project-sessions-btn"
                >
                  全选当前可清理会话
                </button>
              </div>
            </div>

            <div style={{ padding: '6px 14px 110px' }}>
              {loading && sessions.length === 0 ? (
                <div className="hero-center-stage">正在加载项目会话…</div>
              ) : sessions.length === 0 ? (
                <div className="hero-center-stage">
                  {ageFilter === 'all' ? '此项目没有可显示的会话' : '此项目没有 90 天前的会话'}
                </div>
              ) : (
                sessions.map((session) => {
                  const isExpanded = expandedSessionId === session.id;
                  const isLocked = Boolean(session.hardProtectionReason);
                  const recColor = RECOMMENDATION_COLORS[session.recommendation];
                  return (
                    <div
                      key={session.id}
                      style={{
                        borderBottom: '1px solid var(--divider)',
                        padding: '8px 4px',
                      }}
                      data-testid="project-session-row"
                    >
                      <div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
                        {isLocked ? (
                          <span className="check-btn locked" title={session.hardProtectionReason}>
                            <Lock size={11} />
                          </span>
                        ) : (
                          <button
                            type="button"
                            className={`check-btn ${session.selected ? 'checked' : ''}`}
                            style={{ '--check-color': recColor } as React.CSSProperties}
                            disabled={isBusy}
                            onClick={() => void onToggleSessionItem(session, activeProject.projectId, showsAllClients)}
                            aria-label={`勾选会话 ${session.preferredTitle}`}
                          >
                            {session.selected && <Check size={12} strokeWidth={3} />}
                          </button>
                        )}

                        <button
                          type="button"
                          onClick={() => setExpandedSessionId(isExpanded ? null : session.id)}
                          style={{
                            flex: 1,
                            minWidth: 0,
                            border: 'none',
                            background: 'transparent',
                            textAlign: 'left',
                            display: 'flex',
                            alignItems: 'center',
                            gap: 8,
                            padding: '4px 0',
                          }}
                        >
                          {isExpanded ? <ChevronDown size={13} /> : <ChevronRight size={13} />}
                          <div style={{ flex: 1, minWidth: 0 }}>
                            <div
                              style={{
                                fontWeight: 600,
                                overflow: 'hidden',
                                textOverflow: 'ellipsis',
                                whiteSpace: 'nowrap',
                              }}
                            >
                              {session.preferredTitle}
                            </div>
                            <div style={{ fontSize: 11.5, color: 'var(--text-secondary)', display: 'flex', gap: 8 }}>
                              <span>{session.clientName}</span>
                              <span className="mono-num">{formatDateTime(session.modifiedAt)}</span>
                            </div>
                          </div>
                          <span className="mono-num" style={{ fontSize: 12, color: 'var(--text-secondary)', flexShrink: 0 }}>
                            {formatBytes(session.sizeBytes)}
                          </span>
                        </button>

                        <button
                          type="button"
                          className="row-action-btn"
                          title="查看完整标题"
                          onClick={() => onInspectFullTitle(session)}
                        >
                          <MessageSquareText size={13} />
                        </button>
                        <button
                          type="button"
                          className="row-action-btn"
                          title={revealActionTitle(platform)}
                          onClick={() => onRevealItem(session)}
                        >
                          <FolderOpen size={13} />
                        </button>
                      </div>

                      {isExpanded && (
                        <div
                          style={{
                            marginLeft: 38,
                            marginTop: 6,
                            padding: '8px 12px',
                            borderRadius: 10,
                            background: 'var(--surface-muted)',
                            fontSize: 12,
                            display: 'flex',
                            flexDirection: 'column',
                            gap: 6,
                          }}
                        >
                          <div style={{ userSelect: 'text' }}>{session.hardProtectionReason || session.safetyNote}</div>
                          <div className="mono-path" style={{ fontSize: 11, color: 'var(--text-secondary)', wordBreak: 'break-all', userSelect: 'text' }}>
                            {session.path}
                          </div>

                          {session.artifacts && session.artifacts.length > 0 && (
                            <div style={{ marginTop: 4, display: 'flex', flexDirection: 'column', gap: 4 }}>
                              <div style={{ fontWeight: 600, fontSize: 11.5, color: 'var(--text-secondary)' }}>
                                关联文件（{session.artifacts.length}）
                              </div>
                              {session.artifacts.map((art) => {
                                const artLocked = Boolean(art.hardProtectionReason);
                                return (
                                  <div key={art.id} style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                                    {artLocked ? (
                                      <span className="check-btn locked">
                                        <Lock size={10} />
                                      </span>
                                    ) : (
                                      <button
                                        type="button"
                                        className={`check-btn ${art.selected ? 'checked' : ''}`}
                                        style={{ '--check-color': RECOMMENDATION_COLORS[art.recommendation] } as React.CSSProperties}
                                        disabled={isBusy}
                                        onClick={() => void onToggleSessionItem(art, activeProject.projectId, showsAllClients)}
                                      >
                                        {art.selected && <Check size={11} strokeWidth={3} />}
                                      </button>
                                    )}
                                    <span style={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                                      {art.preferredTitle}
                                    </span>
                                    <span className="mono-num" style={{ color: 'var(--text-secondary)' }}>
                                      {formatBytes(art.sizeBytes)}
                                    </span>
                                  </div>
                                );
                              })}
                            </div>
                          )}
                        </div>
                      )}
                    </div>
                  );
                })
              )}
            </div>
          </>
        )}
      </div>
    </div>
  );
}
