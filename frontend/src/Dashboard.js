import React, { useState, useEffect } from 'react';
import { fetchAuthSession } from 'aws-amplify/auth';
import awsConfig from './aws-exports'; 
import AWS from 'aws-sdk';
// Explicit Service Imports
import S3 from 'aws-sdk/clients/s3';
import Lambda from 'aws-sdk/clients/lambda';
import StepFunctions from 'aws-sdk/clients/stepfunctions';

import { 
  Container, Typography, Box, Button, Select, MenuItem, 
  TextField, Paper, CircularProgress, Alert, AppBar, Toolbar, Link 
} from '@mui/material';
import DownloadIcon from '@mui/icons-material/Download';

// --- CONFIGURATION ---
const BUCKET_NAME = "compliance-reporting-bucket-sg-430118833069"; 
const FETCHER_LAMBDA = "compliance-reporting-policy-section-fetcher";
const STEP_FUNCTION_ARN = "arn:aws:states:ap-southeast-1:430118833069:stateMachine:compliance-reporting-workflow";
const REGION = "ap-southeast-1";

const Dashboard = ({ user, signOut }) => {
  const [policies, setPolicies] = useState([]);
  const [selectedPolicy, setSelectedPolicy] = useState('');
  const [prompts, setPrompts] = useState([]);
  
  // UI State
  const [loading, setLoading] = useState(false);
  const [status, setStatus] = useState('');
  const [executionArn, setExecutionArn] = useState('');
  const [reportUrl, setReportUrl] = useState(''); // Store the final download link

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

  const analyzePolicy = async () => {
    if (!selectedPolicy) return;
    setLoading(true);
    setStatus('AI is analyzing policy structure...');
    setReportUrl(''); // Reset previous report
    
    const lambda = new Lambda();
    try {
      const params = {
        FunctionName: FETCHER_LAMBDA,
        Payload: JSON.stringify({ policy_file: selectedPolicy })
      };
      
      const response = await lambda.invoke(params).promise();
      const payload = JSON.parse(response.Payload);
      const sections = payload.sections || [];

      const initialPrompts = sections.map(sec => ({
        section: sec,
        prompt: `Analyze compliance for Policy Section: ${sec}.\n1. Search the Knowledge Base for requirements.\n2. Query the view 'unified_compliance_view' for evidence.\n   - Columns: event_time, user_identity, event_action, resource_target, status_reason, source_system.\n   - DO NOT use 'ILIKE'. Use 'LOWER(column) LIKE'.\n   - DO NOT use date functions. ORDER BY event_time DESC.\n3. If Section 5.9 check for failed logins.\n4. If Section 8.3 check for MFA bypass.\n5. Cite specific log evidence.`
      }));
      
      setPrompts(initialPrompts);
      setStatus('Policy analyzed. Please review prompts below.');
    } catch (err) {
      setStatus(`Error: ${err.message}`);
    } finally {
      setLoading(false);
    }
  };

  const handlePromptChange = (index, newValue) => {
    const updated = [...prompts];
    updated[index].prompt = newValue;
    setPrompts(updated);
  };

  // --- POLLING LOGIC STARTS HERE ---
  const waitForCompletion = async (arn, stepfunctions) => {
    try {
        let isRunning = true;
        
        while (isRunning) {
            // Wait 2 seconds before checking
            await new Promise(resolve => setTimeout(resolve, 2000));
            
            const statusData = await stepfunctions.describeExecution({ executionArn: arn }).promise();
            const state = statusData.status;
            
            if (state === 'SUCCEEDED') {
                setStatus('Audit Complete! Generating download link...');
                
                // Parse output to find S3 Key
                const output = JSON.parse(statusData.output);
                // The output format depends on your Step Function. 
                // Based on main.tf it returns: { "report_location": "s3://bucket/key" }
                const s3Location = output.report_location;
                
                generatePresignedUrl(s3Location);
                isRunning = false;
            } else if (state === 'FAILED' || state === 'TIMED_OUT' || state === 'ABORTED') {
                setStatus(`Workflow Failed: ${state}`);
                setLoading(false);
                isRunning = false;
            } else {
                setStatus(`Audit in progress... Status: ${state}`);
                // Continue loop
            }
        }
    } catch (err) {
        setStatus(`Polling Error: ${err.message}`);
        setLoading(false);
    }
  };

  const generatePresignedUrl = (s3Uri) => {
      // s3Uri looks like: s3://bucket-name/outputs/reports/file.docx
      try {
          const s3 = new S3();
          // Extract Key from URI
          const key = s3Uri.replace(`s3://${BUCKET_NAME}/`, '');
          
          const url = s3.getSignedUrl('getObject', {
              Bucket: BUCKET_NAME,
              Key: key,
              Expires: 3600 // Link valid for 1 hour
          });
          
          setReportUrl(url);
          setStatus('Report Generated Successfully!');
      } catch (err) {
          setStatus('Error generating download link: ' + err.message);
      } finally {
          setLoading(false);
      }
  };

  const startAudit = async () => {
    setLoading(true);
    setReportUrl('');
    setStatus('Starting Audit Workflow...');
    
    const stepfunctions = new StepFunctions();
    try {
      const params = {
        stateMachineArn: STEP_FUNCTION_ARN,
        input: JSON.stringify({
          policy_file: selectedPolicy,
          items: prompts
        })
      };
      
      const result = await stepfunctions.startExecution(params).promise();
      setExecutionArn(result.executionArn);
      
      // Start polling loop
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
        <Paper sx={{ p: 3, mb: 3 }}>
          <Typography variant="h6">1. Select Policy</Typography>
          <Select 
            fullWidth 
            value={selectedPolicy} 
            onChange={(e) => setSelectedPolicy(e.target.value)}
            displayEmpty
            sx={{ mt: 2, mb: 2 }}
          >
            <MenuItem value="" disabled>Select a PDF...</MenuItem>
            {policies.map(p => <MenuItem key={p} value={p}>{p}</MenuItem>)}
          </Select>
          <Button variant="contained" onClick={analyzePolicy} disabled={!selectedPolicy || loading}>
            Analyze Structure
          </Button>
        </Paper>

        {prompts.length > 0 && (
          <Paper sx={{ p: 3, mb: 3 }}>
            <Typography variant="h6">2. Review & Edit AI Prompts</Typography>
            <Typography variant="body2" color="textSecondary" sx={{ mb: 2 }}>
              Customize the instructions for each section before execution.
            </Typography>
            
            {prompts.map((item, idx) => (
              <Box key={idx} sx={{ mb: 3 }}>
                <Typography variant="subtitle1" sx={{ fontWeight: 'bold' }}>{item.section}</Typography>
                <TextField
                  fullWidth
                  multiline
                  rows={4}
                  value={item.prompt}
                  onChange={(e) => handlePromptChange(idx, e.target.value)}
                  variant="outlined"
                />
              </Box>
            ))}
            
            {/* Action Area */}
            <Box sx={{ mt: 2 }}>
                {!reportUrl ? (
                    <Button 
                        variant="contained" 
                        color="success" 
                        size="large" 
                        onClick={startAudit} 
                        disabled={loading}
                        fullWidth
                    >
                        {loading ? <CircularProgress size={24} color="inherit" /> : "🚀 Generate Compliance Report"}
                    </Button>
                ) : (
                    <Button 
                        variant="contained" 
                        color="primary" 
                        size="large" 
                        href={reportUrl} 
                        target="_blank"
                        startIcon={<DownloadIcon />}
                        fullWidth
                    >
                        Download Report
                    </Button>
                )}
            </Box>
          </Paper>
        )}

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