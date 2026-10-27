//! Runs two xara HF modems linked by a noiseless simulated audio path, in real
//! time, each serving the VARA command/data ports like the xara binary does.
//!
//!   xara-airlink [PORT_A] [PORT_B]      (defaults 18500 18600)
//!
//! Station A answers on PORT_A/PORT_A+1, station B on PORT_B/PORT_B+1.
//! Call signs come from the clients' MYCALL commands.

use std::thread;
use std::time::{Duration, Instant};
use xara::station::hf::Station;
use xara::station::Options;
use xara::tnc::Tnc;
use xara_arq::hf::session::Config;
use xara_host::server::Host;
use xara_phy::hf::level::Bandwidth;

const RATE: f64 = 48000.0;
const BLOCK: usize = 480;

fn main() {
    let args: Vec<u16> = std::env::args().skip(1).map(|a| a.parse().expect("port")).collect();
    let ports = [args.first().copied().unwrap_or(18500), args.get(1).copied().unwrap_or(18600)];
    let mut tnc: Vec<Tnc<Station>> = ports
        .iter()
        .zip(["XX0A", "XX0B"])
        .map(|(&p, call)| {
            let st = Station::new(Config::new(Bandwidth::Hz2300, call), Options { drive_db: -5.0, ..Options::default() });
            Tnc::new(st, Host::bind("127.0.0.1", p).expect("bind"))
        })
        .collect();
    println!("xara-airlink: A on {} / {}, B on {} / {}", ports[0], ports[0] + 1, ports[1], ports[1] + 1);
    let mut wire = [vec![0.0f64; BLOCK * 2], vec![0.0f64; BLOCK * 2]];
    let start = Instant::now();
    let mut samples: u64 = 0;
    loop {
        for t in tnc.iter_mut() {
            t.service();
        }
        for i in 0..2 {
            let input: Vec<f64> = wire[1 - i].drain(..BLOCK).collect();
            let mut out = vec![0.0; BLOCK];
            tnc[i].process(&input, &mut out);
            wire[i].extend(out);
        }
        samples += BLOCK as u64;
        let due = Duration::from_secs_f64(samples as f64 / RATE);
        if let Some(wait) = due.checked_sub(start.elapsed()) {
            thread::sleep(wait);
        }
    }
}
