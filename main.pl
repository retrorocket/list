#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use Scalar::Util 'blessed';
use Net::Twitter::Lite::WithAPIv1_1;
use Mojolicious::Lite;
#use Data::Dumper;
use List::Compare;
use JSON;
use POSIX 'setsid';

plugin 'mail';

app->config(hypnotoad => {listen => ['http://*:secret']});
app->hook('before_dispatch' => sub {
	my $self = shift;
	if ($self->req->headers->header('X-Forwarded-Host')) {
		my $path = shift @{$self->req->url->path->parts};
		push @{$self->req->url->base->path->parts}, $path;
	}
});

my $consumer_key ="***";
my $consumer_secret = "***";
my $from_address = "xxx@retrorocket.biz";

my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
	consumer_key => $consumer_key,
	consumer_secret => $consumer_secret,
	ssl => 1
);


get '/' => sub {
	my $self = shift;

	my $access_token = $self->session( 'access_token' ) || '';
	my $access_token_secret = $self->session( 'access_token_secret' ) || '';
	my $screen_name = $self->session( 'screen_name' ) || '';

	#セッションにトークンがないならトップに戻す
	return $self->redirect_to( 'http://retrorocket.biz/list' ) unless ($access_token && $access_token_secret);

	$self->stash('name' => $screen_name);

	my $mail_mode = $self->session('mail') || ''; 
	if($mail_mode) {return $self->render('mail');}

} => 'index';


get '/auth' => sub {
	my $self = shift;
	my $mode = $self->param('mode') || '';
	my $mail = $self->param('mail') || '';

	$self->session( mode => $mode );
	$self->session( mail => $mail );

	my $cb_url = $self->url_for('auth_cb')->to_abs->scheme('https');
	my $url = $nt->get_authorization_url( callback => $cb_url );

	$self->session( token => $nt->request_token );
	$self->session( token_secret => $nt->request_token_secret );

	$self->redirect_to( $url );
} => 'auth';

get '/auth_cb' => sub {
	my $self = shift;

	my $verifier = $self->param('oauth_verifier') || '';
	my $token = $self->session('token') || '';
	my $token_secret = $self->session('token_secret') || '';

	$nt->request_token( $token );
	$nt->request_token_secret( $token_secret );

	my ($access_token, $access_token_secret, $user_id, $screen_name)
	= $nt->request_access_token( verifier => $verifier );

	$self->session( access_token => $access_token );
	$self->session( access_token_secret => $access_token_secret );
	$self->session( screen_name => $screen_name );

	$self->redirect_to( $self->url_for('index')->to_abs->scheme('https') );
} => 'auth_cb';

post '/list' => sub {

	my $self = shift;

	my $access_token = $self->session( 'access_token' ) || '';
	my $access_token_secret = $self->session( 'access_token_secret' ) || '';
	my $screen_name = $self->session( 'screen_name' ) || '';

	my $mode = $self->session('mode') || '';
	my $sender_address = $self->param('address') || 'false';
	my $mail_flag = $sender_address ne "false" ? 1 : 0;

	#トークンなし
	unless ($access_token && $access_token_secret) {
		if($mail_flag == 1){
			$self->mail(
				to      => $sender_address,
				subject => 'TimeLine Copier Result（fault）',
				data    => "TimeLine Copierの処理に失敗しました。：Twitterに認証されていません。" ,
				from    => $from_address
			);
		}
		else {
			return $self->render(json =>{'result' => "fault", 'complete' => -1});
		}
		exit;
	}

	$nt->access_token( $access_token );
	$nt->access_token_secret( $access_token_secret );


	my $filename;
	my $num;
	my $list;
	my $repeat = 0;
	my $only_count = -1;
	my @mem = ();
	my $temp_only = -1;
	my $temp_repeat = 0;
	my $repeat_magic = 2;


	$filename = app->home. "/public/".$screen_name.".json";
	if( -f $filename ) {
		return $self->render(json =>{'result' => "fault", 'complete' => -2});
		exit;
	}
	
	my $pid = fork();
	die "fork fault: $!" unless defined $pid;

	if($pid) {
		# 親プロセス
		$self->session( expires => 1 );
		return $self->render(json =>{'result' => $screen_name, 'complete' => 0 });
		#意味は無いが念のため。
		exit;
	}
	else {
		#子プロセス
		setsid;
		
		open (STDIN, "</dev/null");
		open (STDOUT, ">/dev/null");
		open (STDERR, ">&STDOUT");

		open(OUT, ">$filename");
		my %trig = ();
		$trig{complete} = 0;
		$trig{result} = "Processing ...";
		my $json_out = encode_json(\%trig);
		print OUT $json_out;
		close(OUT);

		do {
			eval {
				if($repeat == 0) {
					$list = $nt->create_list({name=>'home_timeline_copy', mode=>'private', description =>"It\'s processing." });
					$num = $list->{id_str};
					sleep 2;
				
					my $hash;
					if($mode eq 'follower'){
						$hash = $nt->followers_ids({count=>4999, stringify_ids =>'true'});
					}
					else {
						$hash = $nt->friends_ids({count=>4999, stringify_ids=>'true'});
					}
					@mem = @{$hash->{ids}};

					$nt->add_list_member({list_id=>$num, screen_name=>$screen_name});
				}

				while ($only_count != 0 && $temp_repeat < $repeat_magic) {

					$temp_only = $only_count;
	
					my $magic = 50;
					my $count = @mem;

					my $hyaku = int($count / $magic);
					my $amari = $count % $magic;

					my $i = 0;
					for($i = 0; $i < $hyaku; $i++){
						eval {
							my @temp = @mem[$i*$magic ... (($i+1)*$magic)-1];
							my $str = join(',', @temp);
							$nt->add_list_members({list_id=>$num, user_id=>$str});
							sleep 1;
						};
					}
					if($amari > 0){
						eval {
							my @temp = @mem[$hyaku*$magic ... $hyaku*$magic+($amari-1)];
							my $str = join(',', @temp);
							#print $str;
							$nt->add_list_members({list_id=>$num, user_id=>$str});
							sleep 1;
						};
					}

				#リストに登録できた勢
					my $cursor = -1;
					my $list_members = $nt->list_members({list_id => $num, cursor => $cursor});

					my @list_mem;
					for my $a (@{$list_members->{users}}){
						push(@list_mem,$a->{id_str});
					}
					$cursor = $list_members->{next_cursor};
					while ($cursor != 0){
						$list_members = $nt->list_members({list_id => $num, cursor => $cursor});
						for my $a (@{$list_members->{users}}){
							push(@list_mem,$a->{id_str});
						}
						$cursor = $list_members->{next_cursor};
					}

					my $lc = List::Compare->new(\@mem, \@list_mem);
					my @only = $lc->get_Lonly;

					$only_count = @only;
					if($only_count >= $temp_only) {$temp_repeat++;}
					
					@mem = ();
					@mem = @only;

					my $mem_count = @list_mem;
					open(OUT, ">$filename");
					my %trig = ();
					$trig{complete} = 0;
					$trig{repeat} = $temp_repeat;
					$trig{result} = "Processing on ".$mem_count." members (left : ".$only_count." members)";
					my $json_out = encode_json(\%trig);
					print OUT $json_out;
					close(OUT);
	
				}
			};
			if( my $err = $@ ){
				die $@ unless blessed $err && $err->isa('Net::Twitter::Lite::Error');
				my $error = $err->code;
				$repeat++;
				if($mail_flag == 1 && $repeat == 1 && $error != 404){
					$self->mail(
						to      => $sender_address,
						subject => 'TimeLine Copier Result (on process)',
						data    => "TimeLine Copierの処理が中断されました。15分後に処理を再開します。\n".$@ ,
						from    => $from_address
					);
					sleep 900;
				}
				elsif ( ($mail_flag == 1 && $repeat > 1) || ($mail_flag == 1 && $error == 404) ) {
					$self->mail(
						to      => $sender_address,
						subject => 'TimeLine Copier Result (faulted)',
						data    => "TimeLine Copierの処理に失敗しました。\n".$@ ,
						from    => $from_address
					);
					unlink($filename);
					if($error != 404) {
						$nt->update_list({list_id => $num, description => "error : ".$@});
					}
					#$self->session( expires => 1 );
					close (SSTDIN);
					close (STDOUT);
					close (STDERR);
					exit;
				}
				else {
					unlink($filename);
					if($error != 404) {
						$nt->update_list({list_id => $num, description => "error : ".$@});
					}
					#しなくてもいいんだけど
					close (SSTDIN);
					close (STDOUT);
					close (STDERR);
					exit;
				}
			}
		} while($mail_flag == 1 && $repeat == 1);

		if($temp_repeat >= $repeat_magic) {
			if($mail_flag == 1){

				$self->mail(
					to      => $sender_address,
					subject => 'TimeLine Copier Result (faulted)',
					data    => $only_count."名の存在しない・凍結された可能性のあるユーザをリストに登録できませんでした。Twitterを確認して下さい。" ,
					from    => $from_address
				);
			}
			unlink($filename);
			$nt->update_list({list_id => $num, description => $only_count."名の存在しない・凍結された可能性のあるユーザをリストに登録できませんでした"});

			close (SSTDIN);
			close (STDOUT);
			close (STDERR);
			exit;
		}

		if($mail_flag == 1){

			$self->mail(
				to      => $sender_address,
				subject => 'TimeLine Copier Result (succeed)',
				data    => "TimeLine Copierの処理が完了しました。Twitterを確認して下さい。" ,
				from    => $from_address
			);
		}
		unlink($filename);
		$nt->update_list({list_id => $num, description => "succeed"});

		close (SSTDIN);
		close (STDOUT);
		close (STDERR);
		exit;
	}

} => 'list';

# セッション消去（隠しオプション）
get '/logout' => sub {
	my $self = shift;
	$self->session( expires => 1 );
	#$self->render;
} => 'logout';

app->sessions->secure(1);
app->secrets(["xxx"]); # セッション管理のために付けておく
app->start;
