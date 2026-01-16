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
  IconButton, Card, CardContent
} from '@mui/material';
import DownloadIcon from '@mui/icons-material/Download';
import AddIcon from '@mui/icons-material/Add';
import DeleteIcon from '@mui/icons-material/Delete';

// --- CONFIGURATION ---
const BUCKET_NAME = "compliance-reporting-bucket-sg-430118833069"; 
const FETCHER_LAMBDA = "compliance-reporting-policy-section-fetcher";
const STEP_FUNCTION_ARN = "arn:aws:states:ap-southeast-1:430118833069:stateMachine:compliance-reporting-workflow";
const REGION = "ap-southeast-1";

const Dashboard = ({ user, signOut }) => {
  const [policies, setPolicies] = useState([]);
  const [selectedPolicy, setSelectedPolicy] = useState('');
  
  // System Selection State
  const [systems, setSystems] = useState([]);
  const [selectedSystem, setSelectedSystem] = useState('');

  // [NEW] All available sections from analyzed policy
  const [allSections, setAllSections] = useState([]);
  
  // [NEW] Selected sections with their prompts
  const [selectedSections, setSelectedSections] = useState([]);
  
  // UI State
  const [loading, setLoading] = useState(false);
  const [status, setStatus] = useState('');
  const [reportUrl, setReportUrl] = useState('');
  const [policyAnalyzed, setPolicyAnalyzed] = useState(false);

  useEffect(() => {
    const initAWS = async () => {
      try {
        const session = await fetchAuthSession();
        const token = session.tokens?.idToken?.toString();

        if (!token) {
            console.error("No token found");
            return;
        }

        AWS.config.region = REGION;
        AWS.config.credentials = new AWS.CognitoIdentityCredentials({
          IdentityPoolId: awsConfig.Auth.identityPoolId, 
          Logins: {
            [`cognito-idp.${REGION}.amazonaws.com/${awsConfig.Auth.userPoolId}`]: token
          }
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
      const data = await s3.listObjectsV2({
        Bucket: BUCKET_NAME,
        Prefix: 'inputs/policy/'
      }).promise();
      
      const pdfs = (data.Contents || [])
        .filter(obj => obj.Key.endsWith('.pdf'))
        .map(obj => obj.Key);
      setPolicies(pdfs);
    } catch (err) {
      console.error(err);
      setStatus(`Error fetching policies: ${err.message}`);
    }
  };

  const listSystems = async () => {
    const s3 = new S3();
    try {
      const data = await s3.listObjectsV2({
        Bucket: BUCKET_NAME,
        Prefix: 'inputs/SOCreports/',
        Delimiter: '/' 
      }).promise();
      
      const systemFolders = (data.CommonPrefixes || [])
        .map(prefix => {
          const parts = prefix.Prefix.split('/');
          return parts[parts.length - 2]; 
        });

      setSystems(systemFolders);
    } catch (err) {
      console.error(err);
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
      const params = {
        FunctionName: FETCHER_LAMBDA,
        Payload: JSON.stringify({ policy_file: selectedPolicy })
      };
      
      const response = await lambda.invoke(params).promise();
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

  // [NEW] Add a new section selection
  const addSection = () => {
    const newSection = {
      id: Date.now(),
      section: '',
      prompt: ''
    };
    setSelectedSections([...selectedSections, newSection]);
  };

  // [NEW] Remove a section selection
  const removeSection = (id) => {
    setSelectedSections(selectedSections.filter(s => s.id !== id));
  };

  // [NEW] Update section selection
  const updateSection = (id, section) => {
    const updated = selectedSections.map(s => {
      if (s.id === id) {
        return {
          ...s,
          section: section,
          prompt: `Analyze compliance for Policy Section: ${section}.\n1) Search Knowledge Base. 2) If System Name (${selectedSystem}) is provided, check SOC report. 3) Query unified_compliance_view. 4) Cite evidence.`
        };
      }
      return s;
    });
    setSelectedSections(updated);
  };

  // [NEW] Update prompt for a section
  const updatePrompt = (id, prompt) => {
    const updated = selectedSections.map(s => {
      if (s.id === id) {
        return { ...s, prompt };
      }
      return s;
    });
    setSelectedSections(updated);
  };

  const waitForCompletion = async (arn, stepfunctions) => {
    try {
        let isRunning = true;
        
        while (isRunning) {
            await new Promise(resolve => setTimeout(resolve, 3000));
            
            const statusData = await stepfunctions.describeExecution({ executionArn: arn }).promise();
            const state = statusData.status;
            
            if (state === 'SUCCEEDED') {
                setStatus('Audit Complete! Generating download link...');
                const output = JSON.parse(statusData.output);
                const s3Location = output.report_location;
                generatePresignedUrl(s3Location);
                isRunning = false;
            } else if (state === 'FAILED' || state === 'TIMED_OUT' || state === 'ABORTED') {
                setStatus(`Workflow Failed: ${state}`);
                setLoading(false);
                isRunning = false;
            } else {
                setStatus(`Audit in progress... Status: ${state}`);
            }
        }
    } catch (err) {
        setStatus(`Polling Error: ${err.message}`);
        setLoading(false);
    }
  };

  const generatePresignedUrl = (s3Uri) => {
      try {
          const s3 = new S3();
          const key = s3Uri.replace(`s3://${BUCKET_NAME}/`, '');
          const url = s3.getSignedUrl('getObject', {
              Bucket: BUCKET_NAME, Key: key, Expires: 3600 
          });
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

    setLoading(true);
    setReportUrl('');
    setStatus('Starting Audit Workflow...');
    
    const stepfunctions = new StepFunctions();
    try {
      // [IMPORTANT] Build prompts array from selected sections
      const prompts = selectedSections.map(s => ({
        section: s.section,
        prompt: s.prompt
      }));

      const params = {
        stateMachineArn: STEP_FUNCTION_ARN,
        input: JSON.stringify({
          policy_file: selectedPolicy,
          system_name: selectedSystem,
          // [NEW] Pass only selected sections with their prompts
          sections: selectedSections.map(s => s.section),
          custom_prompts: prompts
        })
      };
      
      const result = await stepfunctions.startExecution(params).promise();
      waitForCompletion(result.executionArn, stepfunctions);
      
    } catch (err) {
      setStatus(`Error starting workflow: ${err.message}`);
      setLoading(false);
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
        {/* Step 1 & 2: Policy and System Selection */}
        <Paper sx={{ p: 3, mb: 3 }}>
          <Typography variant="h6" sx={{ mb: 2 }}>Configuration</Typography>
          
          <Typography variant="subtitle2" sx={{ mb: 1 }}>1. Select Policy Document:</Typography>
          <Select 
            fullWidth 
            value={selectedPolicy} 
            onChange={(e) => {
              setSelectedPolicy(e.target.value);
              setPolicyAnalyzed(false);
              setAllSections([]);
              setSelectedSections([]);
            }}
            displayEmpty
            sx={{ mb: 3 }}
          >
            <MenuItem value="" disabled>Select a PDF...</MenuItem>
            {policies.map(p => <MenuItem key={p} value={p}>{p}</MenuItem>)}
          </Select>

          <Typography variant="subtitle2" sx={{ mb: 1 }}>2. Select System for SOC Audit:</Typography>
          <Select 
            fullWidth 
            value={selectedSystem} 
            onChange={(e) => setSelectedSystem(e.target.value)}
            displayEmpty
            sx={{ mb: 3 }}
          >
            <MenuItem value="" disabled>Select System (e.g. CyberArk)...</MenuItem>
            {systems.map(s => <MenuItem key={s} value={s}>{s}</MenuItem>)}
          </Select>

          <Button 
            variant="contained" 
            onClick={analyzePolicy} 
            disabled={!selectedPolicy || !selectedSystem || loading}
          >
            Analyze Structure
          </Button>
        </Paper>

        {/* Step 3: Section Selection with Dropdown */}
        {policyAnalyzed && (
          <Paper sx={{ p: 3, mb: 3 }}>
            <Typography variant="h6" sx={{ mb: 2 }}>Select Sections to Audit</Typography>
            <Typography variant="body2" color="textSecondary" sx={{ mb: 3 }}>
              Choose which policy sections to analyze. You can add multiple sections.
            </Typography>

            {/* Section Selection Cards */}
            {selectedSections.map((item, idx) => (
              <Card key={item.id} sx={{ mb: 3, backgroundColor: '#f5f5f5' }}>
                <CardContent>
                  <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', mb: 2 }}>
                    <Typography variant="subtitle1" sx={{ fontWeight: 'bold' }}>
                      Section {idx + 1}
                    </Typography>
                    <IconButton
                      size="small"
                      onClick={() => removeSection(item.id)}
                      color="error"
                    >
                      <DeleteIcon />
                    </IconButton>
                  </Box>

                  {/* Section Dropdown */}
                  <Typography variant="body2" sx={{ mb: 1 }}>Select Section:</Typography>
                  <Select 
                    fullWidth
                    value={item.section}
                    onChange={(e) => updateSection(item.id, e.target.value)}
                    displayEmpty
                    sx={{ mb: 2 }}
                  >
                    <MenuItem value="" disabled>Choose a section...</MenuItem>
                    {allSections.map(sec => (
                      <MenuItem key={sec} value={sec}>{sec}</MenuItem>
                    ))}
                  </Select>

                  {/* Prompt Text Area */}
                  <Typography variant="body2" sx={{ mb: 1 }}>Prompt:</Typography>
                  <TextField
                    fullWidth
                    multiline
                    rows={4}
                    value={item.prompt}
                    onChange={(e) => updatePrompt(item.id, e.target.value)}
                    placeholder="Edit the prompt for this section..."
                  />
                </CardContent>
              </Card>
            ))}

            {/* Add Section Button */}
            <Box sx={{ display: 'flex', gap: 2, mb: 3 }}>
              <Button
                variant="outlined"
                startIcon={<AddIcon />}
                onClick={addSection}
                disabled={selectedSections.length === 0 && allSections.length === 0}
              >
                Add Section
              </Button>
              {selectedSections.length === 0 && (
                <Button
                  variant="contained"
                  startIcon={<AddIcon />}
                  onClick={addSection}
                >
                  Select First Section
                </Button>
              )}
            </Box>

            {/* Generate Report Button */}
            {selectedSections.length > 0 && (
              <Box sx={{ mt: 3 }}>
                {!reportUrl ? (
                    <Button 
                        variant="contained" 
                        color="success" 
                        size="large" 
                        fullWidth
                        onClick={startAudit} 
                        disabled={loading || selectedSections.some(s => !s.section)}
                    >
                        {loading ? <CircularProgress size={24} color="inherit" /> : "🚀 Generate Compliance Report"}
                    </Button>
                ) : (
                    <Button 
                        variant="contained" 
                        color="primary" 
                        size="large" 
                        fullWidth
                        href={reportUrl} 
                        target="_blank" 
                        startIcon={<DownloadIcon />}
                    >
                        Download Report
                    </Button>
                )}
              </Box>
            )}
          </Paper>
        )}

        {/* Status Messages */}
        {status && (
          <Alert severity={status.includes("Error") || status.includes("Failed") ? "error" : "info"} sx={{ mt: 2 }}>
            {status}
          </Alert>
        )}
      </Container>
    </Box>
  );
};

export default Dashboard;
