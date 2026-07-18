import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/auth/view_models/auth_view_model.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSignUp = false;

  void _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    
    if (email.isEmpty || password.isEmpty) return;

    final authVm = ref.read(authViewModelProvider.notifier);
    if (_isSignUp) {
      await authVm.signUp(email, password);
    } else {
      await authVm.signIn(email, password);
    }

    final authState = ref.read(authViewModelProvider);
    if (authState.hasError && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(authState.error.toString(), style: const TextStyle(color: Colors.white)),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authViewModelProvider);

    // If authenticated successfully, the router redirect will automatically handle it,
    // but we can also react here just in case.
    ref.listen(authViewModelProvider, (previous, next) {
      if (next.hasValue && next.value != null) {
        context.go('/chat');
      }
    });

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        children: [
          // Background Gradient Orbs
          Positioned(
            top: -100,
            left: -100,
            child: Container(
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.primary.withValues(alpha: 0.15),
              ),
            ).animate().fadeIn(duration: const Duration(seconds: 1)).scale(),
          ),
          Center(
            child: Container(
              width: 400,
              padding: const EdgeInsets.all(40),
              decoration: BoxDecoration(
                color: AppTheme.surface.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppTheme.surfaceHighlight),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 40,
                    offset: const Offset(0, 20),
                  )
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.change_history, color: AppTheme.primary, size: 48),
                      const SizedBox(height: 24),
                      Text(
                        _isSignUp ? 'Create Account' : 'Welcome Back',
                        style: GoogleFonts.inter(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isSignUp ? 'Join Veraxi today.' : 'Sign in to access your agents.',
                        style: GoogleFonts.inter(
                          color: AppTheme.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 32),
                      TextField(
                        controller: _emailController,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          hintText: 'Email Address',
                          prefixIcon: Icon(Icons.email_outlined, color: AppTheme.textSecondary),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _passwordController,
                        obscureText: true,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          hintText: 'Password',
                          prefixIcon: Icon(Icons.lock_outline, color: AppTheme.textSecondary),
                        ),
                      ),
                      const SizedBox(height: 32),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: authState.isLoading ? null : _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            elevation: 0,
                          ),
                          child: authState.isLoading
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                )
                              : Text(
                                  _isSignUp ? 'Sign Up' : 'Sign In',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _isSignUp = !_isSignUp;
                          });
                        },
                        child: Text(
                          _isSignUp ? 'Already have an account? Sign in' : "Don't have an account? Sign up",
                          style: TextStyle(color: AppTheme.textSecondary),
                        ),
                      )
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Back Button
          Positioned(
            top: 40,
            left: 40,
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: AppTheme.textSecondary),
              onPressed: () => context.go('/'),
            ),
          )
        ],
      ),
    );
  }
}
