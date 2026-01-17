import React, { useState, useEffect } from 'react';
import { fetchAuthSession } from 'aws-amplify/auth';
import awsConfig from './aws-exports'; 
import AWS from 'aws-sdk';
import S3 from 'aws-sdk/clients/s3';
import Lambda from 'aws-sdk/clients/lambda';
import StepFunctions from 'aws-sdk/clients/stepfunctions';
import DynamoDB from 'aws-sdk/clients/dynamodb';

import { 
  Container, Typography, Box, Button, Select, MenuItem, 
  TextField, Paper, CircularProgress, Alert, AppBar, Toolbar,
  IconButton, Card, CardContent, Modal, LinearProgress, Stepper, Step, StepLabel,
  Tabs, Tab, Table, TableBody, TableCell, TableContainer, TableHead, TableRow
} from '@mui/material';
import DownloadIcon from '@mui/icons-material/Download';
import AddIcon from '@mui/icons-material/Add';
import DeleteIcon from '@mui/icons-material/Delete';
import CheckCircleIcon from '@mui/icons-material/CheckCircle';
import ErrorIcon from '@mui/icons-material/Error';
import HistoryIcon from '@mui/icons-material/History';
import AssessmentIcon from '@mui/icons-material/Assessment';
import ArrowBackIcon from '@mui/icons-material/ArrowBack';
import CloseIcon from '@mui/icons-material/Close';

// --- CONFIGURATION ---
const BUCKET_NAME = "compliance-reporting-bucket-sg-430118833069"; 
const FETCHER_LAMBDA = "compliance-reporting-policy-section-fetcher";
const STEP_FUNCTION_ARN = "arn:aws:states:ap-southeast-1:430118833069:stateMachine:compliance-reporting-workflow";
const AUDIT_HISTORY_TABLE = "compliance-reporting-audit-history";
const REGION = "ap-southeast-1";

const STAGES = [
  { key: 'starting', label: 'Starting Workflow' },
  { key: 'analyzing', label: 'Analyzing Sections' },
  { key: 'generating', label: 'Generating Report' },
  { key: 'complete', label: 'Complete' }
];

const Dashboard = ({ user, signOut }) => {
  // Tab state
  const [activeTab, setActiveTab] = useState(0);
  
  // Audit tab state
  const [policies, setPolicies] = useState([]);
  const [selectedPolicy, setSelectedPolicy] = useState('');
  const [systems, setSystems] = useState([]);
  const [selectedSystem, setSelectedSystem] = useState('');
  const [allSections, setAllSections] = useState([]);
  const [selectedSections, setSelectedSections] = useState([]);
  const [loading, setLoading] = useState(false);
  const [status, setStatus] = useState('');
  const [reportUrl, setReportUrl] = useState('');
  const [policyAnalyzed, setPolicyAnalyzed] = useState(false);

  // Report view state
  const [showReportView, setShowReportView] = useState(false);
  const [reportContent, setReportContent] = useState('');

  // Progress modal state
  const [progressOpen, setProgressOpen] = useState(false);
  const [currentStage, setCurrentStage] = useState(0);
  const [progressMessage, setProgressMessage] = useState('');
  const [workflowFailed, setWorkflowFailed] = useState(false);

  // History tab state
  const [auditHistory, setAuditHistory] = useState([]);
  const [historyLoading, setHistoryLoading] = useState(false);

  const getUserId = () => {
    return user?.username || user?.signInDetails?.loginId || 'unknown';
  };

  useEffect(() => {
    const initAWS = async () => {
      try {
        const session = await fetchAuthSession();
        const token = session.tokens?.idToken?.toString();
        if (!token) { console.error("No token found"); return; }

        AWS.config.region = REGION;
        AWS.config.credentials = new AWS.CognitoIdentityCredentials({
          IdentityPoolId: awsConfig.Auth.identityPoolId, 
          Logins: { [`cognito-idp.${REGION}.amazonaws.com/${awsConfig.Auth.userPoolId}`]: token }
        });
        
        listPolicies();
        listSystems();
      } catch (err) {
        console.error("Error initializing AWS:", err);
        setStatus("Authentication error: " + err.message);
      }
    };
    initAWS();
  }, []);

  // Load history when tab changes to History
  useEffect(() => {
    if (activeTab === 1) {
      loadAuditHistory();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeTab]);

  const listPolicies = async () => {
    const s3 = new S3();
    try {
      const data = await s3.listObjectsV2({ Bucket: BUCKET_NAME, Prefix: 'inputs/policy/' }).promise();
      const pdfs = (data.Contents || []).filter(obj => obj.Key.endsWith('.pdf')).map(obj => obj.Key);
      setPolicies(pdfs);
    } catch (err) {
      setStatus(`Error fetching policies: ${err.message}`);
    }
  };

  const listSystems = async () => {
    const s3 = new S3();
    try {
      const data = await s3.listObjectsV2({ Bucket: BUCKET_NAME, Prefix: 'inputs/SOCreports/', Delimiter: '/' }).promise();
      const systemFolders = (data.CommonPrefixes || []).map(prefix => prefix.Prefix.split('/').slice(-2)[0]);
      setSystems(systemFolders);
    } catch (err) {
      setStatus(`Error fetching systems: ${err.message}`);
    }
  };

  const loadAuditHistory = async () => {
    setHistoryLoading(true);
    const dynamodb = new DynamoDB.DocumentClient();
    try {
      const result = await dynamodb.query({
        TableName: AUDIT_HISTORY_TABLE,
        KeyConditionExpression: 'user_id = :uid',
        ExpressionAttributeValues: { ':uid': getUserId() },
        ScanIndexForward: false,
        Limit: 50
      }).promise();
      setAuditHistory(result.Items || []);
    } catch (err) {
      console.error('Error loading history:', err);
      setAuditHistory([]);
    } finally {
      setHistoryLoading(false);
    }
  };

  const saveAuditHistory = async (reportKey, sections, prompts) => {
    const dynamodb = new DynamoDB.DocumentClient();
    try {
      await dynamodb.put({
        TableName: AUDIT_HISTORY_TABLE,
        Item: {
          user_id: getUserId(),
          timestamp: new Date().toISOString(),
          policy_file: selectedPolicy,
          system_name: selectedSystem,
          sections: sections,
          prompts: prompts,
          report_s3_key: reportKey
        }
      }).promise();
    } catch (err) {
      console.error('Error saving history:', err);
    }
  };

  const getPresignedUrl = (s3Key) => {
    const s3 = new S3();
    return s3.getSignedUrl('getObject', { Bucket: BUCKET_NAME, Key: s3Key, Expires: 3600 });
  };

  const fetchReportContent = async (s3Key) => {
    const s3 = new S3();
    try {
      const data = await s3.getObject({ Bucket: BUCKET_NAME, Key: s3Key }).promise();
      const content = data.Body.toString('utf-8');
      setReportContent(content);
    } catch (err) {
      console.error('Error fetching report content:', err);
      setReportContent('Error loading report content');
    }
  };

  const analyzePolicy = async () => {
    if (!selectedPolicy) return;
    setLoading(true);
    setStatus('AI is analyzing policy structure...');
    setReportUrl('');
    setPolicyAnalyzed(false);
    setSelectedSections([]);
    
    const lambda = new Lambda();
    try {
      const response = await lambda.invoke({
        FunctionName: FETCHER_LAMBDA,
        Payload: JSON.stringify({ policy_file: selectedPolicy })
      }).promise();
      const payload = JSON.parse(response.Payload);
      const sections = payload.sections || [];
      setAllSections(sections);
      setPolicyAnalyzed(true);
      setStatus(`Policy analyzed. Found ${sections.length} sections. Select sections below.`);
    } catch (err) {
      setStatus(`Error: ${err.message}`);
    } finally {
      setLoading(false);
    }
  };

  const addSection = () => {
    setSelectedSections([...selectedSections, { id: Date.now(), section: '', prompt: '' }]);
  };

  const removeSection = (id) => {
    setSelectedSections(selectedSections.filter(s => s.id !== id));
  };

  const updateSection = (id, section) => {
    setSelectedSections(selectedSections.map(s => s.id === id ? {
      ...s, section,
      prompt: `Analyze compliance for Policy Section: ${section}.\n1) Search Knowledge Base. 2) If System Name (${selectedSystem}) is provided, check SOC report. 3) Query unified_compliance_view. 4) Cite evidence.`
    } : s));
  };

  const updatePrompt = (id, prompt) => {
    setSelectedSections(selectedSections.map(s => s.id === id ? { ...s, prompt } : s));
  };

  const getStageFromState = (stateName) => {
    if (stateName?.includes('AnalyzeSection') || stateName?.includes('AnalyzeSectionsInParallel') || stateName?.includes('FormatFinding')) return 1;
    if (stateName?.includes('GenerateReport')) return 2;
    if (stateName?.includes('WorkflowComplete')) return 3;
    return 0;
  };

  const waitForCompletion = async (arn, stepfunctions, prompts) => {
    try {
      let isRunning = true;
      while (isRunning) {
        await new Promise(resolve => setTimeout(resolve, 2000));
        const statusData = await stepfunctions.describeExecution({ executionArn: arn }).promise();
        const state = statusData.status;
        
        try {
          const history = await stepfunctions.getExecutionHistory({ executionArn: arn, reverseOrder: true, maxResults: 50 }).promise();
          const latestStateEntered = history.events?.find(e => e.stateEnteredEventDetails);
          const currentStateName = latestStateEntered?.stateEnteredEventDetails?.name;
          setCurrentStage(getStageFromState(currentStateName));
          setProgressMessage(currentStateName ? `Processing: ${currentStateName}` : 'Processing...');
        } catch (histErr) {
          console.log('Could not fetch history:', histErr);
        }
        
        if (state === 'SUCCEEDED') {
          setCurrentStage(3);
          setProgressMessage('Report generated successfully!');
          const output = JSON.parse(statusData.output);
          const docxKey = output.report_location.replace(`s3://${BUCKET_NAME}/`, '');
          const htmlKey = output.html_key; // New: HTML key from Lambda
          
          setReportUrl(getPresignedUrl(docxKey));
          setStatus('Report Generated Successfully!');
          setLoading(false);
          
          // Save to history
          await saveAuditHistory(docxKey, selectedSections.map(s => s.section), prompts);
          
          // Fetch HTML report content for display
          if (htmlKey) {
            await fetchReportContent(htmlKey);
          }
          
          isRunning = false;
          // Close modal and show report view
          setTimeout(() => {
            setProgressOpen(false);
            setShowReportView(true);
          }, 1000);
        } else if (state === 'FAILED' || state === 'TIMED_OUT' || state === 'ABORTED') {
          setWorkflowFailed(true);
          setProgressMessage(`Workflow ${state.toLowerCase()}`);
          setStatus(`Workflow Failed: ${state}`);
          setLoading(false);
          isRunning = false;
        }
      }
    } catch (err) {
      setWorkflowFailed(true);
      setProgressMessage(`Error: ${err.message}`);
      setStatus(`Polling Error: ${err.message}`);
      setLoading(false);
    }
  };

  const startAudit = async () => {
    if (selectedSections.length === 0) {
      setStatus('Please select at least one section');
      return;
    }

    setLoading(true);
    setReportUrl('');
    setReportContent('');
    setShowReportView(false);
    setProgressOpen(true);
    setCurrentStage(0);
    setProgressMessage('Initializing workflow...');
    setWorkflowFailed(false);
    setStatus('');
    
    const stepfunctions = new StepFunctions();
    try {
      const prompts = selectedSections.map(s => ({ section: s.section, prompt: s.prompt }));
      const result = await stepfunctions.startExecution({
        stateMachineArn: STEP_FUNCTION_ARN,
        input: JSON.stringify({
          policy_file: selectedPolicy,
          system_name: selectedSystem,
          sections: selectedSections.map(s => s.section),
          custom_prompts: prompts
        })
      }).promise();
      
      setProgressMessage('Workflow started...');
      waitForCompletion(result.executionArn, stepfunctions, prompts);
    } catch (err) {
      setStatus(`Error starting workflow: ${err.message}`);
      setLoading(false);
      setProgressOpen(false);
    }
  };

  const closeProgressModal = () => {
    if (!loading || workflowFailed) setProgressOpen(false);
  };

  // Go back to audit form (preserves selections)
  const handleGoBack = () => {
    setShowReportView(false);
  };

  // Close and reset to fresh audit
  const handleCloseReport = () => {
    setShowReportView(false);
    setReportUrl('');
    setReportContent('');
    setSelectedSections([]);
    setPolicyAnalyzed(false);
    setSelectedPolicy('');
    setSelectedSystem('');
    setStatus('');
  };

  const formatDate = (isoString) => {
    return new Date(isoString).toLocaleString();
  };

  return (
    <Box sx={{ flexGrow: 1 }}>
      <AppBar position="static">
        <Toolbar>
          <Typography variant="h6" component="div" sx={{ flexGrow: 1 }}>
            Compliance Auditor Control Center
          </Typography>
          <Typography variant="body2" sx={{ mr: 2 }}>{getUserId()}</Typography>
          <Button color="inherit" onClick={signOut}>Sign Out</Button>
        </Toolbar>
      </AppBar>

      <Container maxWidth="lg" sx={{ mt: 2 }}>
        {/* Only show tabs when not in report view */}
        {!showReportView && (
          <Tabs value={activeTab} onChange={(e, v) => setActiveTab(v)} sx={{ mb: 3 }}>
            <Tab icon={<AssessmentIcon />} label="New Audit" />
            <Tab icon={<HistoryIcon />} label="History" />
          </Tabs>
        )}

        {/* REPORT VIEW */}
        {showReportView && (
          <Paper sx={{ p: 3, mb: 3 }}>
            <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 2 }}>
              <Typography variant="h5">📋 Compliance Report</Typography>
              <Button variant="contained" href={reportUrl} target="_blank" startIcon={<DownloadIcon />}>
                Download DOCX
              </Button>
            </Box>

            <Paper 
              variant="outlined" 
              sx={{ 
                p: 0, 
                maxHeight: '60vh', 
                overflow: 'auto',
                backgroundColor: '#fff'
              }}
            >
              {reportContent ? (
                <div dangerouslySetInnerHTML={{ __html: reportContent }} />
              ) : (
                <Box sx={{ display: 'flex', justifyContent: 'center', p: 4 }}>
                  <CircularProgress />
                </Box>
              )}
            </Paper>

            <Box sx={{ display: 'flex', gap: 2, mt: 3 }}>
              <Button variant="outlined" startIcon={<ArrowBackIcon />} onClick={handleGoBack}>
                Go Back
              </Button>
              <Button variant="outlined" color="error" startIcon={<CloseIcon />} onClick={handleCloseReport}>
                Close & New Audit
              </Button>
            </Box>
          </Paper>
        )}

        {/* TAB 0: New Audit (hidden when showing report) */}
        {activeTab === 0 && !showReportView && (
          <>
            <Paper sx={{ p: 3, mb: 3 }}>
              <Typography variant="h6" sx={{ mb: 2 }}>Configuration</Typography>
              
              <Typography variant="subtitle2" sx={{ mb: 1 }}>1. Select Policy Document:</Typography>
              <Select 
                fullWidth value={selectedPolicy} 
                onChange={(e) => { setSelectedPolicy(e.target.value); setPolicyAnalyzed(false); setAllSections([]); setSelectedSections([]); }}
                displayEmpty sx={{ mb: 3 }}
              >
                <MenuItem value="" disabled>Select a PDF...</MenuItem>
                {policies.map(p => <MenuItem key={p} value={p}>{p}</MenuItem>)}
              </Select>

              <Typography variant="subtitle2" sx={{ mb: 1 }}>2. Select System for SOC Audit:</Typography>
              <Select 
                fullWidth value={selectedSystem} 
                onChange={(e) => setSelectedSystem(e.target.value)}
                displayEmpty sx={{ mb: 3 }}
              >
                <MenuItem value="" disabled>Select System (e.g. CyberArk)...</MenuItem>
                {systems.map(s => <MenuItem key={s} value={s}>{s}</MenuItem>)}
              </Select>

              <Button variant="contained" onClick={analyzePolicy} disabled={!selectedPolicy || !selectedSystem || loading}>
                Analyze Structure
              </Button>
            </Paper>

            {policyAnalyzed && (
              <Paper sx={{ p: 3, mb: 3 }}>
                <Typography variant="h6" sx={{ mb: 2 }}>Select Sections to Audit</Typography>
                <Typography variant="body2" color="textSecondary" sx={{ mb: 3 }}>
                  Choose which policy sections to analyze. You can add multiple sections.
                </Typography>

                {selectedSections.map((item, idx) => (
                  <Card key={item.id} sx={{ mb: 3, backgroundColor: '#f5f5f5' }}>
                    <CardContent>
                      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', mb: 2 }}>
                        <Typography variant="subtitle1" sx={{ fontWeight: 'bold' }}>Section {idx + 1}</Typography>
                        <IconButton size="small" onClick={() => removeSection(item.id)} color="error"><DeleteIcon /></IconButton>
                      </Box>
                      <Typography variant="body2" sx={{ mb: 1 }}>Select Section:</Typography>
                      <Select fullWidth value={item.section} onChange={(e) => updateSection(item.id, e.target.value)} displayEmpty sx={{ mb: 2 }}>
                        <MenuItem value="" disabled>Choose a section...</MenuItem>
                        {allSections.map(sec => <MenuItem key={sec} value={sec}>{sec}</MenuItem>)}
                      </Select>
                      <Typography variant="body2" sx={{ mb: 1 }}>Prompt:</Typography>
                      <TextField fullWidth multiline rows={4} value={item.prompt} onChange={(e) => updatePrompt(item.id, e.target.value)} placeholder="Edit the prompt..." />
                    </CardContent>
                  </Card>
                ))}

                <Box sx={{ display: 'flex', gap: 2, mb: 3 }}>
                  <Button variant="outlined" startIcon={<AddIcon />} onClick={addSection}>Add Section</Button>
                  {selectedSections.length === 0 && <Button variant="contained" startIcon={<AddIcon />} onClick={addSection}>Select First Section</Button>}
                </Box>

                {selectedSections.length > 0 && (
                  <Box sx={{ mt: 3 }}>
                    <Button variant="contained" color="success" size="large" fullWidth onClick={startAudit} disabled={loading || selectedSections.some(s => !s.section)}>
                      {loading ? <CircularProgress size={24} color="inherit" /> : "🚀 Generate Compliance Report"}
                    </Button>
                  </Box>
                )}
              </Paper>
            )}

            {status && (
              <Alert severity={status.includes("Error") || status.includes("Failed") ? "error" : "info"} sx={{ mt: 2 }}>
                {status}
              </Alert>
            )}
          </>
        )}

        {/* TAB 1: History */}
        {activeTab === 1 && !showReportView && (
          <Paper sx={{ p: 3 }}>
            <Typography variant="h6" sx={{ mb: 2 }}>Audit History</Typography>
            
            {historyLoading ? (
              <Box sx={{ display: 'flex', justifyContent: 'center', p: 4 }}>
                <CircularProgress />
              </Box>
            ) : auditHistory.length === 0 ? (
              <Typography color="textSecondary">No audit history found.</Typography>
            ) : (
              <TableContainer>
                <Table>
                  <TableHead>
                    <TableRow>
                      <TableCell>Date</TableCell>
                      <TableCell>System</TableCell>
                      <TableCell>Sections</TableCell>
                      <TableCell>Prompts</TableCell>
                      <TableCell>Report</TableCell>
                    </TableRow>
                  </TableHead>
                  <TableBody>
                    {auditHistory.map((item, idx) => (
                      <TableRow key={idx}>
                        <TableCell>{formatDate(item.timestamp)}</TableCell>
                        <TableCell>{item.system_name}</TableCell>
                        <TableCell>
                          {(item.sections || []).map((s, i) => (
                            <Typography key={i} variant="body2">{s}</Typography>
                          ))}
                        </TableCell>
                        <TableCell sx={{ maxWidth: 300 }}>
                          {(item.prompts || []).map((p, i) => (
                            <Typography key={i} variant="body2" sx={{ fontSize: '0.75rem', mb: 1 }} noWrap title={p.prompt}>
                              {p.prompt?.substring(0, 80)}...
                            </Typography>
                          ))}
                        </TableCell>
                        <TableCell>
                          <Button 
                            size="small" 
                            startIcon={<DownloadIcon />}
                            href={getPresignedUrl(item.report_s3_key)} 
                            target="_blank"
                          >
                            Download
                          </Button>
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </TableContainer>
            )}
          </Paper>
        )}
      </Container>

      {/* Progress Modal */}
      <Modal open={progressOpen} onClose={closeProgressModal}>
        <Box sx={{
          position: 'absolute', top: '50%', left: '50%', transform: 'translate(-50%, -50%)',
          width: 500, bgcolor: 'background.paper', borderRadius: 2, boxShadow: 24, p: 4
        }}>
          <Typography variant="h6" sx={{ mb: 3, textAlign: 'center' }}>
            {workflowFailed ? '❌ Workflow Failed' : currentStage === 3 ? '✅ Report Ready!' : '🔄 Generating Report...'}
          </Typography>

          <Stepper activeStep={currentStage} alternativeLabel sx={{ mb: 3 }}>
            {STAGES.map((stage, idx) => (
              <Step key={stage.key} completed={currentStage > idx}>
                <StepLabel 
                  error={workflowFailed && currentStage === idx}
                  StepIconComponent={workflowFailed && currentStage === idx ? () => <ErrorIcon color="error" /> : 
                    currentStage > idx ? () => <CheckCircleIcon color="success" /> : undefined}
                >
                  {stage.label}
                </StepLabel>
              </Step>
            ))}
          </Stepper>

          {currentStage === 1 && (
            <Box sx={{ mb: 2 }}>
              <Typography variant="body2" sx={{ mb: 1 }}>
                Analyzing {selectedSections.length} section{selectedSections.length > 1 ? 's' : ''}...
              </Typography>
            </Box>
          )}

          <Typography variant="body2" color="textSecondary" sx={{ textAlign: 'center', mb: 2 }}>
            {progressMessage}
          </Typography>

          {!workflowFailed && currentStage < 3 && <LinearProgress sx={{ mb: 2 }} />}

          {workflowFailed && (
            <Button fullWidth variant="outlined" onClick={() => setProgressOpen(false)}>Close</Button>
          )}
        </Box>
      </Modal>
    </Box>
  );
};

export default Dashboard;
