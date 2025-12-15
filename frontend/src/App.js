import React from 'react';
import { Amplify } from 'aws-amplify';
import { Authenticator } from '@aws-amplify/ui-react';
import '@aws-amplify/ui-react/styles.css';
import awsConfig from './aws-exports';
import Dashboard from './Dashboard'; 

// --- FIX: CONVERT CONFIG TO AMPLIFY V6 FORMAT ---
Amplify.configure({
  Auth: {
    Cognito: {
      userPoolId: awsConfig.Auth.userPoolId,
      userPoolClientId: awsConfig.Auth.userPoolWebClientId,
      identityPoolId: awsConfig.Auth.identityPoolId,
      loginWith: { // This is the key v6 requires!
        email: true,
      },
      signUpVerificationMethod: "code",
      userAttributes: {
        email: {
          required: true,
        },
      },
      allowGuestAccess: false,
      passwordFormat: {
        minLength: 8,
        requireLowercase: true,
        requireUppercase: true,
        requireNumbers: true,
        requireSpecialCharacters: false,
      },
    },
  },
});
// ------------------------------------------------

export default function App() {
  return (
    <Authenticator>
      {({ signOut, user }) => (
        <main>
          <Dashboard user={user} signOut={signOut} />
        </main>
      )}
    </Authenticator>
  );
}