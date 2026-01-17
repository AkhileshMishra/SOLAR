import React, { useState, useEffect } from 'react';
import { fetchAuthSession } from 'aws-amplify/auth';
import awsConfig from './aws-exports'; 
import AWS from 'aws-sdk';
import S3 from 'aws-sdk/clients/s3';
import Lambda from 'aws-sdk/clients/lambda';
import StepFunctions from 'aws-sdk/clients/stepfunctions';

import { 
  Container, Typography, Box, Button, Select, MenuItem, 
  TextField, Paper, CircularProgress, Alert, AppBar, Toolbar,
  IconButton, Card, CardContent, Modal, LinearProgress, Stepper, Step, StepLabel
} from '@mui/material';
import DownloadIcon from '@mui/icons-material/Download';
import AddIcon from '@mui/icons-material/Add';
import DeleteIcon from '@mui/icons-material/Delete';
import CheckCircleIcon from '@mui/icons-material/CheckCircle';
import ErrorIcon from '@mui/icons-material/Error';

// --- CONFIGURATION ---
const BUCKET_NAME = "compliance-reporting-bucket-sg-430118833069"; 
const FETCHER_LAMBDA = "compliance-reporting-policy-section-fetcher";
const STEP_FUNCTION_ARN = "arn:aws:states:ap-southeast-1:430118833069:stateMachine:compliance-reporting-workflow";
const REGION = "ap-southeast-1";

// Progress stages mapping
const STAGES = [
  { key: 'starting', label: 'Starting Workflow' },
  { key: 'analyzing', label: 'Analyzing Sections' },
  { key: 'generating', label: 'Generating Report' },
  { key: 'complete', label: 'Complete' }
];

const Dashboard = ({ user, signOut }) => {
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

  // Progress modal state
  const [progressOpen, setProgressOpen] = useState(false);
  const [currentStage, setCurrentStage] = useState(0);
  const [progressMessage, setProgressMessage] = useState('');
  const [sectionsProgress, setSectionsProgress] = useState({ completed: 0, total: 0 });
  const [workflowFailed, setWorkflowFailed] = useState(false);

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

  const getStageFromState = (stateName, events) => {
    if (stateName?.includes('AnalyzeSection') || stateName?.includes('AnalyzeSectionsInParallel')) {
      // Count completed sections from events
      const completedSections = events?.filter(e => 
        e.type === 'MapIterationSucceeded' || 
        (e.stateExitedEventDetails?.name === 'FormatFinding')
      ).length || 0;
      setSectionsProgress({ completed: completedSections, total: selectedSections.length });
      return 1;
    }
    if (stateName?.includes('GenerateReport')) return 2;
    if (stateName?.includes('WorkflowComplete')) return 3;
    return 0;
  };

  const waitForCompletion = async (arn, stepfunctions) => {
    try {
      let isRunning = true;
      
      while (isRunning) {
        await new Promise(resolve => setTimeout(resolve, 2000));
        
        const statusData = await stepfunctions.describeExecution({ executionArn: arn }).promise();
        const state = statusData.status;
        
        // Get execution history for detailed progress
        try {
          const history = await stepfunctions.getExecutionHistory({ 
            executionArn: arn, 
            reverseOrder: true,
            maxResults: 50
          }).promise();
          
          const latestStateEntered = history.events?.find(e => e.stateEnteredEventDetails);
          const currentStateName = latestStateEntered?.stateEnteredEventDetails?.name;
          
          const stage = getStageFromState(currentStateName, history.events);
          setCurrentStage(stage);
          setProgressMessage(currentStateName ? `Processing: ${currentStateName}` : 'Processing...');
        } catch (histErr) {
          console.log('Could not fetch history:', histErr);
        }
        
        if (state === 'SUCCEEDED') {
          setCurrentStage(3);
          setProgressMessage('Report generated successfully!');
          const output = JSON.parse(statusData.output);
          generatePresignedUrl(output.report_location);
          isRunning = false;
          setTimeout(() => setProgressOpen(false), 1500);
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

  const generatePresignedUrl = (s3Uri) => {
    try {
      const s3 = new S3();
      const key = s3Uri.replace(`s3://${BUCKET_NAME}/`, '');
      const url = s3.getSignedUrl('getObject', { Bucket: BUCKET_NAME, Key: key, Expires: 3600 });
      setReportUrl(url);
      setStatus('Report Generated Successfully!');
    } catch (err) {
      setStatus('Error generating link: ' + err.message);
    } finally {
      setLoading(false);
    }
  };

  const startAudit = async () => {
    if (selectedSections.length === 0) {
      setStatus('Please select at least one section');
      return;
    }

    // Reset and open progress modal
    setLoading(true);
    setReportUrl('');
    setProgressOpen(true);
    setCurrentStage(0);
    setProgressMessage('Initializing workflow...');
    setSectionsProgress({ completed: 0, total: selectedSections.length });
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
      waitForCompletion(result.executionArn, stepfunctions);
    } catch (err) {
      setStatus(`Error starting workflow: ${err.message}`);
      setLoading(false);
      setProgressOpen(false);
    }
  };

  const closeProgressModal = () => {
    if (!loading || workflowFailed) {
      setProgressOpen(false);
    }
  };

  return (
    <Box sx={{ flexGrow: 1 }}>
      <AppBar position="static">
        <Toolbar>
          <Typography variant="h6" component="div" sx={{ flexGrow: 1 }}>
            Compliance Auditor Control Center
          </Typography>
          <Button color="inherit" onClick={signOut}>Sign Out</Button>
        </Toolbar>
      </AppBar>

      <Container maxWidth="lg" sx={{ mt: 4 }}>
        {/* Configuration Section */}
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

        {/* Section Selection */}
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
                {!reportUrl ? (
                  <Button variant="contained" color="success" size="large" fullWidth onClick={startAudit} disabled={loading || selectedSections.some(s => !s.section)}>
                    {loading ? <CircularProgress size={24} color="inherit" /> : "🚀 Generate Compliance Report"}
                  </Button>
                ) : (
                  <Button variant="contained" color="primary" size="large" fullWidth href={reportUrl} target="_blank" startIcon={<DownloadIcon />}>
                    Download Report
                  </Button>
                )}
              </Box>
            )}
          </Paper>
        )}

        {status && (
          <Alert severity={status.includes("Error") || status.includes("Failed") ? "error" : "info"} sx={{ mt: 2 }}>
            {status}
          </Alert>
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

          {currentStage === 1 && sectionsProgress.total > 0 && (
            <Box sx={{ mb: 2 }}>
              <Typography variant="body2" sx={{ mb: 1 }}>
                Analyzing sections: {sectionsProgress.completed} / {sectionsProgress.total}
              </Typography>
              <LinearProgress 
                variant="determinate" 
                value={(sectionsProgress.completed / sectionsProgress.total) * 100} 
              />
            </Box>
          )}

          <Typography variant="body2" color="textSecondary" sx={{ textAlign: 'center', mb: 2 }}>
            {progressMessage}
          </Typography>

          {!workflowFailed && currentStage < 3 && (
            <LinearProgress sx={{ mb: 2 }} />
          )}

          {(workflowFailed || currentStage === 3) && (
            <Button fullWidth variant="outlined" onClick={() => setProgressOpen(false)}>
              Close
            </Button>
          )}
        </Box>
      </Modal>
    </Box>
  );
};

export default Dashboard;
