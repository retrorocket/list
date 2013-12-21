#!/usr/bin/perl

use strict;
use warnings;
use utf8;
#use KCatch;
use LWP::Protocol::Net::Curl;
use Net::Twitter::Lite::WithAPIv1_1;
use Mojolicious::Lite;

my $consumer_key ="***";
my $consumer_secret = "***";

my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
	consumer_key => $consumer_key,
	consumer_secret => $consumer_secret,
	ssl => 1
);

# トップページ
get '/' => sub {
	my $self = shift;
	my $mode = $self->param('mode') || 'following';
	$self->redirect_to( '/auth/'.$mode );

} => 'index';

get '/auth/:mode'  => {mode => undef} => sub {
	my $self = shift;
	my $mode = $self->param('mode') || 'following';
	my $cb_url = 'https://retrorocket.biz/list/auth.cgi/auth_cb/'.$mode;
	my $url = $nt->get_authorization_url( callback => $cb_url );

	$self->session( token => $nt->request_token );
	$self->session( token_secret => $nt->request_token_secret );

	$self->redirect_to( $url );
} => 'auth';

get '/auth_cb/:mode' => {mode => undef}  => sub {
	my $self = shift;
	my $mode = $self->param('mode') || 'following';
	my $verifier = $self->param('oauth_verifier') || '';
	my $token = $self->session('token') || '';
	my $token_secret = $self->session('token_secret') || '';

	$nt->request_token( $token );
	$nt->request_token_secret( $token_secret );

	# トークン取得
	my ($access_token, $access_token_secret, $user_id, $screen_name)
		= $nt->request_access_token( verifier => $verifier );

	# セッションに格納
	$self->session( access_token => $access_token );
	$self->session( access_token_secret => $access_token_secret );
	$self->session( screen_name => $screen_name );

	if($mode ne 'following'){
		$self->redirect_to( 'https://retrorocket.biz/list/list.cgi?mode=follower' );
	}
	else {
		$self->redirect_to( 'https://retrorocket.biz/list/list.cgi' );
	}
} => 'auth_cb';

# セッション削除
get '/logout' => sub {
	my $self = shift;
	$self->session( expires => 1 );
} => 'logout';

app->sessions->secure(1);
app->secret("***"); # セッション管理のために付けておく
app->start;

